"""Chronological A-D ablations. Select Ridge alpha using validation only; test once."""
import argparse, json
from pathlib import Path
import numpy as np
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import Ridge
from sklearn.ensemble import RandomForestRegressor
from features import SCHEMA, INPUT_NAMES
from evaluate import metrics, strata

GROUPS={'A':list(range(5))+[16,17,18], 'B':list(range(8))+[16,17,18],
        'C':list(range(10))+[16,17,18], 'D':list(range(19))}
def train(dataset, output):
    rows=sorted(dataset['rows'],key=lambda r:r['sourceTimestamp'])
    if dataset['schema']!=SCHEMA or dataset['inputNames']!=INPUT_NAMES: raise ValueError('Schema mismatch')
    if len(rows)<300: raise ValueError('Need >=300 usable rows; multiple weeks recommended for real evaluation')
    a,b=int(len(rows)*.70),int(len(rows)*.85)
    validation_start=rows[a]['sourceTimestamp']; test_start=rows[b]['sourceTimestamp']
    # Purge rows whose labels cross either boundary (including the matching tolerance).
    splits=[[r for r in rows[:a] if max(r['targetTimes']) < validation_start and r['sourceTimestamp']+3750<validation_start],
            [r for r in rows[a:b] if max(r['targetTimes']) < test_start and r['sourceTimestamp']+3750<test_start],rows[b:]]
    if any(len(s)<20 for s in splits): raise ValueError('Insufficient rows after 60-minute boundary purge')
    def arrays(rs): return np.array([r['input'] for r in rs]),np.array([r['targets'] for r in rs])
    (xt,yt),(xv,yv),(xe,ye)=map(arrays,splits)
    report={'schema':SCHEMA,'quality':dataset['quality'],'splitCounts':list(map(len,splits)),
            'splitSourceTimeRanges':[[s[0]['sourceTimestamp'],s[-1]['sourceTimestamp']] for s in splits],
            'persistence':metrics(ye,np.repeat(xe[:,0,None],2,axis=1),xe[:,0]),'experiments':{},
            'limitations':['No calibrated low-risk probability','P90 absolute residual is not a confidence interval',
                          'No clinical validation','Clarke/Parkes grid and event warning lead time require separate validation',
                          'Sleep/exercise stratification is limited by context coverage; overnight uses UTC']}
    candidates={}
    for group,indices in GROUPS.items():
        columns=indices+[i+19 for i in indices]
        results=[]
        for alpha in (0.1,1.,10.,100.):
            model=make_pipeline(StandardScaler(),Ridge(alpha=alpha))
            model.fit(xt[:,columns],yt)
            score=np.mean(np.abs(model.predict(xv[:,columns])-yv)); results.append((score,alpha,model))
        score,alpha,model=min(results,key=lambda item:item[0]); pred=model.predict(xe[:,columns])
        report['experiments'][group]={'ridgeAlpha':alpha,'validationMAE':float(score),
            'test':metrics(ye,pred,xe[:,0],[r['lowWithin60'] for r in splits[2]]),
            'strata':strata(splits[2],ye,pred,xe[:,0])}
        # Additional nonlinear model kept offline; Core ML deployment remains the auditable linear model.
        forest=RandomForestRegressor(n_estimators=80,max_depth=8,min_samples_leaf=10,random_state=42,n_jobs=-1)
        forest.fit(xt[:,columns],yt)
        report['experiments'][group]['forestTest']=metrics(ye,forest.predict(xe[:,columns]),xe[:,0])
        candidates[group]=(float(score),model,columns)
    selected=min(candidates,key=lambda g:candidates[g][0]); _,model,columns=candidates[selected]
    scaler,ridge=model.steps[0][1],model.steps[1][1]
    weights=np.zeros((2,38)); weights[:,columns]=ridge.coef_/scaler.scale_
    bias=ridge.intercept_ - np.sum(ridge.coef_*scaler.mean_/scaler.scale_,axis=1)
    residual=np.quantile(np.abs(model.predict(xv[:,columns])-yv),.9,axis=0)
    report['selected']=selected
    output.mkdir(parents=True,exist_ok=True)
    manifest={'schema':SCHEMA,'modelVersion':'ridge-v1-'+selected,'inputNames':INPUT_NAMES,'residualP90':residual.tolist(),
              'input':'features','output':'forecast','selectedExperiment':selected}
    (output/'linear_model.json').write_text(json.dumps({'weights':weights.tolist(),'bias':bias.tolist()},indent=2))
    (output/'forecast_manifest.json').write_text(json.dumps(manifest,indent=2))
    (output/'report.json').write_text(json.dumps(report,indent=2,allow_nan=False))
    parity=[{'input':r['input'],'expected':(weights@np.array(r['input'])+bias).tolist()} for r in splits[2][:10]]
    (output/'prediction_fixtures.json').write_text(json.dumps(parity,indent=2))
    print(json.dumps({'selected':selected,'splitCounts':report['splitCounts']},indent=2))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('dataset');p.add_argument('--output',default='artifacts');a=p.parse_args()
    train(json.loads(Path(a.dataset).read_text()),Path(a.output))

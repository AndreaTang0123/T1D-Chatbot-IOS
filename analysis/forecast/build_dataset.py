"""Build supervised rows from a user-initiated Joe research export; never reads old repo secrets."""
import argparse, json
from pathlib import Path
from features import normalize, feature_row, nearest_actual, SCHEMA, INPUT_NAMES

def build(export):
    glucose,treatments,contexts=normalize(export)
    rows=[]
    for index,sample in enumerate(glucose):
        # Restrict expensive matching and feature construction to a causal local window.
        t=sample['t']
        nearby=[r for r in glucose[max(0,index-20):index+15] if t-2100<=r['t']<=t+3750]
        row=feature_row(nearby,[r for r in treatments if t-86400<=r['t']<=t],
                        [r for r in contexts if t-900<=r['t']<=t],t)
        if row is None: continue
        actuals=[nearest_actual(nearby,t+h*60) for h in (30,60)]
        if any(r is None for r in actuals): continue
        future=[r['g'] for r in nearby if t<r['t']<=t+3600]
        row['targets']=[r['g'] for r in actuals]
        row['targetTimes']=[r['t'] for r in actuals]
        # Low-event labels require complete future coverage, not just the two endpoints.
        complete=all(nearest_actual(nearby,t+offset*300) is not None for offset in range(1,13))
        row['lowWithin60']=int(min(future)<70) if future and complete else None
        rows.append(row)
    coverage={name:sum(name in r['missing'] for r in rows)/max(1,len(rows)) for name in __import__('features').NAMES}
    return {'schema':SCHEMA,'inputNames':INPUT_NAMES,'rows':rows,
            'quality':{'glucoseSamples':len(glucose),'usableRows':len(rows),'missingFraction':coverage}}
if __name__=='__main__':
    p=argparse.ArgumentParser(); p.add_argument('export'); p.add_argument('--output',default='data/dataset.json'); a=p.parse_args()
    result=build(json.loads(Path(a.export).read_text())); out=Path(a.output); out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(json.dumps(result,indent=2,allow_nan=False)); print(json.dumps(result['quality'],indent=2))

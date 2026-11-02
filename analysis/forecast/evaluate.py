"""Offline research metrics. No clinical-validation claims."""
import numpy as np

def metrics(actual, predicted, current, low_labels=None):
    error=np.asarray(predicted)-actual
    out={'mae':np.mean(np.abs(error),axis=0).tolist(),'rmse':np.sqrt(np.mean(error**2,axis=0)).tolist()}
    persistence=np.mean(np.abs(current[:,None]-actual),axis=0)
    out['improvementOverPersistence']=(persistence-np.array(out['mae'])).tolist()
    # Endpoint threshold screen only, not calibrated risk of a low anywhere in the hour.
    if low_labels is not None:
        valid=np.array([v is not None for v in low_labels]); truth=np.array([bool(v) for v in low_labels])[valid]
        alert=(np.min(predicted,axis=1)<70)[valid]
        out['endpointScreenSensitivity']=float(np.mean(alert[truth])) if np.any(truth) else None
        out['endpointScreenSpecificity']=float(np.mean(~alert[~truth])) if np.any(~truth) else None
        out['lowLabelCoverage']=float(np.mean(valid))
    return out

def strata(rows, actual, predicted, current):
    masks={'meal':[r['values'][8]>0 and 'carbs_2h' not in r['missing'] for r in rows],
           'exercise':[r['values'][12]>0 and 'workout_active' not in r['missing'] for r in rows],
           'overnightUTC':[int((r['sourceTimestamp']%86400)//3600)<6 for r in rows]}
    return {name:{'count':int(np.sum(mask)), **metrics(actual[np.array(mask)],predicted[np.array(mask)],current[np.array(mask)])}
            for name,mask in masks.items() if any(mask)}

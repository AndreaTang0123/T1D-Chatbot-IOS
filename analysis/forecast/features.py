"""joe.features.v1: causal transforms shared with Swift FeatureBuilder; all times UTC."""
from datetime import datetime, timezone
import math
SCHEMA = 'joe.features.v1'
NAMES = ['glucose','delta_5m','slope_15m','mean_30m','std_30m','basal_rate','bolus_30m',
         'estimated_iob','carbs_2h','estimated_cob','steps_30m','heart_rate','workout_active',
         'sleep_hours','place','calendar','hour_sin','hour_cos','weekday']
INPUT_NAMES = NAMES + ['missing_'+n for n in NAMES]
PLACES = ['unknown','home','school','work','gym','restaurant','other']
CATEGORIES = ['other','class','meeting','meal','travel','medical','exercise']
def timestamp(value):
    if isinstance(value, (float, int)): return float(value)
    parsed = datetime.fromisoformat(value.replace('Z','+00:00'))
    if parsed.tzinfo is None: raise ValueError('Timezone required')
    return parsed.timestamp()
def normalize(export):
    glucose = {}
    for row in export.get('glucose', []):
        t=timestamp(row['timestamp']); g=float(row['glucose'])
        if math.isfinite(g) and 40 <= g <= 400: glucose[t]={'t':t,'g':g}
    treatments=[]
    for row in export.get('treatments',[]):
        treatments.append(dict(row,t=timestamp(row['timestamp'])))
    contexts=[]
    for row in export.get('contexts',[]): contexts.append(dict(row,t=timestamp(row['timestamp'])))
    return sorted(glucose.values(),key=lambda r:r['t']), sorted(treatments,key=lambda r:r['t']), sorted(contexts,key=lambda r:r['t'])
def feature_row(glucose, treatments, contexts, t):
    past=[r for r in glucose if r['t']<=t and math.isfinite(r['g']) and 40<=r['g']<=400]
    if not past or t-past[-1]['t']>900: return None
    source=past[-1]['t']; grid=[]
    for i in range(7):
        target=source+(i-6)*300
        candidates=[r for r in past if r['t']<=target and target-r['t']<=150]
        if not candidates: return None
        grid.append(candidates[-1]['g'])
    mean=sum(grid)/7
    values=[grid[6],grid[6]-grid[5],(grid[6]-grid[3])/15,mean,math.sqrt(sum((g-mean)**2 for g in grid)/7)]
    events=[r for r in treatments if r['t']<=source]
    basal=[r.get('rate') for r in events if r.get('kind','').lower()=='temp basal' and r.get('rate') is not None and (r.get('duration') or 0)>(source-r['t'])/60]
    bolus=[r['insulin'] for r in events if source-r['t']<=1800 and r.get('insulin') is not None]
    carbs=[r['carbs'] for r in events if source-r['t']<=7200 and r.get('carbs') is not None]
    cs=[r for r in contexts if r['t']<=source and source-r['t']<=900]
    c=cs[-1] if cs else {}
    optional=[basal[-1] if basal else None, sum(bolus) if bolus else None, None,
              sum(carbs) if carbs else None, None,c.get('steps'),c.get('heartRate'),
              float(c['workoutActive']) if c.get('workoutActive') is not None else None,c.get('sleepHours'),
              PLACES.index(c['place']) if c.get('place') in PLACES else None,
              CATEGORIES.index(c['calendar']) if c.get('calendar') in CATEGORIES else None]
    missing=[]
    for name,value in zip(NAMES[5:16],optional):
        if value is None or not math.isfinite(value): missing.append(name); values.append(0.)
        else: values.append(float(value))
    dt=datetime.fromtimestamp(source, timezone.utc); phase=(dt.hour*3600+dt.minute*60+dt.second)/86400*2*math.pi
    values += [math.sin(phase),math.cos(phase),float(dt.weekday())]
    return {'timestamp': math.floor(source/300)*300, 'sourceTimestamp':source,'values':values,
            'missing':missing,'input':values+[float(n in missing) for n in NAMES]}
def nearest_actual(glucose,target):
    candidates=[r for r in glucose if abs(r['t']-target)<=150]
    return min(candidates,key=lambda r:abs(r['t']-target)) if candidates else None

from pathlib import Path
import sys,json
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'analysis/forecast'))
from features import feature_row
fixtures=[]
for index in range(4):
    t=1800000000+index*86400
    glucose=[{'t':t+(i-6)*300,'g':100+i*(index+1)} for i in range(7)]
    treatments=[] if index==0 else [{'id':'bolus','t':t-600,'kind':'Meal Bolus','insulin':1.5,'carbs':20},
                                    {'id':'basal','t':t-300,'kind':'Temp Basal','rate':.8,'duration':30}]
    contexts=[] if index<2 else [{'t':t,'steps':125.,'heartRate':75.,'workoutActive':False,'sleepHours':7.,'place':'home','calendar':'class'}]
    expected=feature_row(glucose,treatments,contexts,t)['input']
    fixtures.append(dict(glucose=glucose,treatments=treatments,contexts=contexts,at=t,expected=expected))
(root/'Tests/JoeCoreTests/Fixtures/feature_parity.json').write_text(json.dumps(fixtures,indent=2))

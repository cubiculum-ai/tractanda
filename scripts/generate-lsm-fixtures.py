import json
from pathlib import Path
import numpy as np
rng=np.random.default_rng(1481)
fixtures=[]
def add(name,a,rank,tolerance=1e-9):
    u,s,v=np.linalg.svd(a,full_matrices=False)
    size=min(rank,np.sum(s>s[0]*1e-10))
    fixtures.append(dict(name=name,columns=a.T.tolist(),dimensions=rank,singularValues=s[:size].tolist(),projector=(u[:,:size]@u[:,:size].T).tolist(),tolerance=tolerance))
add('diagonal',np.diag([3.,2.,1.]),2)
add('rectangular',np.array([[1,2,3],[4,5,6],[2,1,0],[0,1,0]],dtype=float),3)
add('repeated singular values retained together',np.diag([5.,3.,3.,0.]),3)
add('rank deficient',np.array([[1,2,3],[2,4,6],[0,0,0]],dtype=float),3)
# A wide sparse matrix with a rapidly decaying spectrum exercises randomized subspace iteration.
u,_=np.linalg.qr(rng.normal(size=(45,30)));v,_=np.linalg.qr(rng.normal(size=(50,30)))
a=(u*np.geomspace(10,1e-7,30))@v.T
add('wide subspace iteration',a,5,2e-7)
Path('Tests/TractandaLearningTests/Fixtures/svd.json').write_text(json.dumps(fixtures,indent=2)+'\n')

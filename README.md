## nsfcareer-build-compute-docker

### To setup 
1. ```docker pull nsfcareer/multipleviewport:production```
2. ```docker pull nsfcareer/mergepolydata:develop```
3. ```docker pull nsfcareer/compute:production```
4. ```docker pull nsfcareer/femtech:production```
5. ```mkdir builddocker```
6. ```cp simulation.sh builddocker/```
7. ```docker build --pull --cache-from nsfcareer/mergepolydata:develop --target mergepolydata --tag nsfcareer/mergepolydata:develop -f Dockerfile builddocker```
8. ```docker build --pull --cache-from nsfcareer/mergepolydata:develop --cache-from nsfcareer/multipleviewport:production --target multiviewport --tag nsfcareer/multipleviewport:production -f Dockerfile builddocker```
9. ```docker build --pull --cache-from nsfcareer/femtech:production --cache-from nsfcareer/multipleviewport:production --cache-from nsfcareer/compute:production --cache-from nsfcareer/mergepolydata:develop --tag nsfcareer/compute:production -f Dockerfile builddocker```
10. ```docker login```
11. ```docker push nsfcareer/multipleviewport:production```
12. ```docker push nsfcareer/mergepolydata:develop```
13. ```docker push nsfcareer/compute:production```

use Time, BlockDist;
config const rows, cols = 100;
config const niter = 500;
config const tolerance = 1e-4: real(32);
var count = 0: int;
var delta: real(32);
var tmp: real(32);

const mesh: domain(2) = {1..rows, 1..cols};
const largerMesh: domain(2) dmapped new blockDist(boundingBox=mesh) = {0..rows+1, 0..cols+1};
var T, Tnew: [largerMesh] real(32);
T[1..rows,1..cols] = 25;

delta = tolerance*10;
var watch: stopwatch;
watch.start();
for i in 1..rows do T[i,cols+1] = (80.0*i/rows):real(32);   // right side boundary condition
for j in 1..cols do T[rows+1,j] = (80.0*j/cols):real(32);   // bottom side boundary condition
while (count < niter && delta >= tolerance) {
  count += 1;
  forall (i,j) in largerMesh[1..rows,1..cols] do
    Tnew[i,j] = 0.25 * (T[i-1,j] + T[i+1,j] + T[i,j-1] + T[i,j+1]);
  delta = max reduce abs(Tnew[1..rows,1..cols]-T[1..rows,1..cols]);
  if count%100 == 0 then writeln("delta = ", delta);
  T[1..rows,1..cols] = Tnew[1..rows,1..cols];   // uses parallel `forall` underneath
}
watch.stop();

writeln('Largest temperature difference was ', delta);
writeln('Converged after ', count, ' iterations');
writeln('Simulation took ', watch.elapsed(), ' seconds');
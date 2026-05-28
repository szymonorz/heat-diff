use Render3D;
use StencilDist;
use CommDiagnostics;
use Time;

config const nx = 20, ny = 20, nz = 20,
             numSteps = 100,
             subSteps = 10,
             alpha = 0.25,
             hotThickness = 2,
             debug = false;

var initTimer, computeTimer: stopwatch;

initTimer.start();

const domain3D = stencilDist.createDomain({0..<nx, 0..<ny, 0..<nz}, fluff=(1,1,1));
const interior  = domain3D.expand(-1);

var u: [domain3D] real = 1.0;

u[.., 0..hotThickness-1, ..] = 2.0;

var un = u;

const dx = 1.0 / (nx - 1),
      dy = 1.0 / (ny - 1),
      dz = 1.0 / (nz - 1);

const cfl = 1.0 / (2.0 * alpha * (1.0/(dx*dx) + 1.0/(dy*dy) + 1.0/(dz*dz)));
const dt  = cfl * 0.98;
const ax  = alpha * dt / (dx*dx),
      ay  = alpha * dt / (dy*dy),
      az  = alpha * dt / (dz*dz);

initTimer.stop();
writeln("Initialization time: ", initTimer.elapsed(), " s");

if debug then startCommDiagnostics();

computeTimer.start();

for step in 1..numSteps {
  for sub in 1..subSteps {
    un.updateFluff();
    forall (i,j,k) in interior do
      u[i,j,k] = un[i,j,k]
                + ax * (un[i-1,j,k] - 2*un[i,j,k] + un[i+1,j,k])
                + ay * (un[i,j-1,k] - 2*un[i,j,k] + un[i,j+1,k])
                + az * (un[i,j,k-1] - 2*un[i,j,k] + un[i,j,k+1]);

    un <=> u;
  }

  renderFrame(un);
}

computeTimer.stop();

if debug {
  stopCommDiagnostics();
  printCommDiagnosticsTable();
}

writeln("Computation time:    ", computeTimer.elapsed(), " s");

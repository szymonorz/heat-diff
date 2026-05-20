use ImageUtils;
use BlockDist;

config const n = 20,
             numSteps = 100,
             alpha = 0.25;

const fullDomain = blockDist.createDomain({0..<n}),
      interior   = fullDomain.expand(-1);

var u: [fullDomain] real = 1.0; 
const dx = 1.0 / (n - 1);
const cfl = dx * dx / (2.0 * alpha);
const dt = cfl * 0.9;
const a = alpha * dt/(dx*dx);

u[0..n/4] = 2.0;
u[3*n/4..n] = 2.0;

var un = u;

for 1..numSteps {
  forall i in interior do
    u[i] = un[i] + a * (un[i-1] - 2*un[i] + un[i+1]);  
  un <=> u;

  renderFrame(un);
}

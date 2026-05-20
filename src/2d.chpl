use ImageUtils;
use StencilDist;
use CommDiagnostics;

config const nx = 50, ny = 50,
             numSteps = 100,
             alpha = 0.25,
             debug = false,
             heatSourceX = -1,
             heatSourceY = -1,
             heatSourceTemp = 2.0;

proc isHeatSourceCell(srcX: int, srcY: int, x: int, globalY: int): bool {
  const minSize = min(nx, ny);

  const baseHalfWidth     = max(8, min(nx / 3, minSize / 3));
  const baseHalfThickness = max(1, minSize / 45);

  const finHeight        = max(8, minSize / 4);
  const finHalfThickness = 1;

  const finCount   = if minSize >= 80 then 7 else 5;
  const finSpacing = max(3, (2 * baseHalfWidth) / max(1, finCount - 1));

  const inBase = abs(globalY - srcY) <= baseHalfThickness &&
                 abs(x - srcX)       <= baseHalfWidth;
  if inBase then return true;

  const baseTopY = srcY - baseHalfThickness;
  const finTopY  = baseTopY - finHeight;

  if globalY < finTopY || globalY > baseTopY then return false;

  const firstFinX = srcX - ((finCount - 1) * finSpacing) / 2;

  for i in 0..<finCount {
    const finX = firstFinX + i * finSpacing;
    if abs(x - finX) <= finHalfThickness then return true;
  }

  return false;
}

const domain2D = stencilDist.createDomain({0..<nx, 0..<ny});
const interior = domain2D.expand(-1);

var u: [domain2D] real = 1.0;

// Apply heat source if srcX/srcY configured, otherwise fall back to corner patches
const srcX = if heatSourceX >= 0 then heatSourceX else nx / 2;
const srcY = if heatSourceY >= 0 then heatSourceY else ny / 2;

forall (i, j) in domain2D do
  if isHeatSourceCell(srcX, srcY, i, j) then
    u[i, j] = heatSourceTemp;

var un = u;

const dx = 1.0/(nx-1);
const dy = 1.0/(ny-1);

const cfl = 1.0 / (2.0 * alpha * (1.0/(dx * dx) + 1.0/(dy * dy)));
const dt = cfl * 0.9;
const ax = alpha * dt / (dx*dx);
const ay = alpha * dt / (dy*dy);

if debug then startCommDiagnostics();

for step in 1..numSteps {
  forall (i,j) in interior do
    if isHeatSourceCell(srcX, srcY, i, j)
      then u[i,j] = heatSourceTemp;
      else u[i,j] = un[i,j] +
                    ax * (un[i-1,j] - 2*un[i,j] + un[i+1,j]) +
                    ay * (un[i,j-1] - 2*un[i,j] + un[i,j+1]);

  un <=> u;
}

if debug {
  stopCommDiagnostics();
  printCommDiagnosticsTable();
}
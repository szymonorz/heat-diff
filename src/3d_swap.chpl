use StencilDist;
use CommDiagnostics;
use MemDiagnostics;
use Time;
use IO;
use FileSystem;
use Subprocess;

config const nx = 20, ny = 20, nz = 20,
             numSteps = 100,
             alpha = 0.25,
             hotThickness = 2,
             debug = false;

config const dumpDir = "frames";
config const dumpEvery = 1;
config const compress = true;
config const trackMem = false;

proc reportMem(msg: string) {
  for loc in Locales do on loc do
    writeln("[mem] ", msg, " locale ", here.id, ": ",
            memoryUsed():real / (1024*1024), " MB");
}

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

proc stepOnce(ref dst, ref src, ref fluffTimer, ref computeTimer) {
  fluffTimer.start();
  src.updateFluff();
  fluffTimer.stop();

  computeTimer.start();
  forall (i,j,k) in interior do
    dst[i,j,k] = src[i,j,k]
               + ax * (src[i-1,j,k] - 2*src[i,j,k] + src[i+1,j,k])
               + ay * (src[i,j-1,k] - 2*src[i,j,k] + src[i,j+1,k])
               + az * (src[i,j,k-1] - 2*src[i,j,k] + src[i,j,k+1]);
  computeTimer.stop();
}

proc dumpLocal(ref field, frameIdx: int) throws {
  coforall loc in Locales do on loc {
    const ld = field.localSubdomain();
    try { mkdir(dumpDir, parents=true); } catch { }
    const base = dumpDir + "/frame_" + frameIdx:string + "_loc_" + here.id:string + ".bin";
    var block: [ld] real = field[ld];

    proc writeAll(ref w) throws {
      w.writeBinary(frameIdx);
      w.writeBinary(here.id);
      for d in 0..2 {
        w.writeBinary(field.domain.dim(d).low);
        w.writeBinary(field.domain.dim(d).high);
      }
      for d in 0..2 {
        w.writeBinary(ld.dim(d).low);
        w.writeBinary(ld.dim(d).high);
      }
      w.writeBinary(block);
    }

    if compress {
      var sub = spawnshell("gzip -c > '" + base + ".gz'", stdin=pipeStyle.pipe);
      var w = sub.stdin;
      writeAll(w);
      w.close();
      sub.wait();
    } else {
      var w = openWriter(base, locking=false);
      writeAll(w);
      w.close();
    }
  }
}

initTimer.stop();
writeln("Initialization time: ", initTimer.elapsed(), " s");
if trackMem then reportMem("after init (u+un allocated)");

coforall loc in Locales do on loc {
  try { if exists(dumpDir) then rmTree(dumpDir); } catch { }
  try { mkdir(dumpDir, parents=true); } catch { }
}

if debug then startCommDiagnostics();

computeTimer.start();

var frame = 0;
for step in 1..numSteps {
  var fluffT, computeT, swapT, saveT: stopwatch;

  stepOnce(u, un, fluffT, computeT);

  swapT.start();
  un <=> u;
  swapT.stop();

  saveT.start();
  if step % dumpEvery == 0 {
    frame += 1;
    dumpLocal(un, frame);
  }
  saveT.stop();

  writeln("step ", step,
          "  updateFluff=", fluffT.elapsed(), " s",
          "  compute=",     computeT.elapsed(), " s",
          "  swap=",        swapT.elapsed(), " s",
          "  save=",        saveT.elapsed(), " s");
}

computeTimer.stop();

if debug {
  stopCommDiagnostics();
  printCommDiagnosticsTable();
}

if trackMem then reportMem("after run");

writeln("final field: min=", min reduce un, " max=", max reduce un,
        " sum=", + reduce un);

writeln("Computation time:    ", computeTimer.elapsed(), " s");

// Single-locale post-processing aggregator.
//
// Reads the per-locale binary slab dumps written by 3d.chpl's dumpLocal()
// (frame_<f>_loc_<id>.bin), reconstructs the full nx*ny*nz field for each
// frame, and renders it via the SAME Render3D.renderFrame used inline before.
// This keeps all heavy rendering OFF the distributed solver's critical path.
//
// Build: chpl --main-module aggregate3d src/aggregate3d.chpl src/Render3D.chpl -o aggregate3d
// Run:   ./aggregate3d --render=true --nx=.. --ny=.. --nz=.. --numFrames=<numSteps> --dumpDir=collected
//
// Collect the per-host `frames/` directories into one `dumpDir` first (e.g. via
// scp from each host in hosts.txt), since the solver writes to each host's local FS.

use Render3D;        // reused unchanged: renderFrame(u: [] real) where rank == 3
use IO;
use FileSystem;
use Subprocess;

config const dumpDir   = "collected";
config const nx = 20, ny = 20, nz = 20;
config const numFrames = 100;

proc main() throws {
  for f in 1..numFrames {
    var full: [0..<nx, 0..<ny, 0..<nz] real;
    var found = 0;

    // read one slab from reader r into full (header layout matches dumpLocal)
    proc readInto(ref r) throws {
      var frameIdx, locId: int;
      r.readBinary(frameIdx);
      r.readBinary(locId);

      // global lo/hi per dim — present in the header but not needed here
      var g: int;
      for d in 0..5 do r.readBinary(g);

      // local lo/hi per dim
      var lo, hi: [0..2] int;
      for d in 0..2 {
        r.readBinary(lo[d]);
        r.readBinary(hi[d]);
      }

      const blockDom = {lo[0]..hi[0], lo[1]..hi[1], lo[2]..hi[2]};
      var block: [blockDom] real;
      r.readBinary(block);
      full[blockDom] = block;
    }

    // matches both .bin and .bin.gz
    for path in glob(dumpDir + "/frame_" + f:string + "_loc_*.bin*") {
      if path.endsWith(".gz") {
        var sub = spawnshell("gunzip -c '" + path + "'", stdout=pipeStyle.pipe);
        var r = sub.stdout;
        readInto(r);
        sub.wait();
      } else {
        var r = openReader(path, locking=false);
        readInto(r);
        r.close();
      }
      found += 1;
    }

    if found == 0 {
      writeln("warning: no dump files found for frame ", f, " in ", dumpDir);
      continue;
    }

    renderFrame(full);   // writes heat3d.mp4 when --render=true
  }

  writeln("Aggregated and rendered ", numFrames, " frame(s) from ", dumpDir);
}

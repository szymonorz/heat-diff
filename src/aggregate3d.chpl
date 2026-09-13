use ImageUtils;
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

    proc readInto(ref r) throws {
      var frameIdx, locId: int;
      r.readBinary(frameIdx);
      r.readBinary(locId);

      var g: int;
      for d in 0..5 do r.readBinary(g);

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

    renderFrame(full);
  }

  writeln("Aggregated and rendered ", numFrames, " frame(s) from ", dumpDir);
}

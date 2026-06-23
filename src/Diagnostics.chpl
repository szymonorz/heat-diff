// Multilocale diagnostics helpers: per-locale memory reporting, halo-exchange byte
// volume, and aggregate communication counts. Re-exports the standard CommDiagnostics /
// MemDiagnostics so `use Diagnostics;` is enough.
module Diagnostics {
  public use CommDiagnostics;
  public use MemDiagnostics;
  use Types;   // numBits

  // Per-locale resident memory, tagged with `msg`.
  proc reportMem(msg: string) {
    for loc in Locales do on loc do
      writeln("[mem] ", msg, " locale ", here.id, ": ",
              memoryUsed():real / (1024*1024), " MB");
  }

  // Bytes a single halo exchange (updateFluff with fluff=1) moves across the network:
  // summed over locales, the fluff cells each must RECEIVE from neighbors x element size.
  // Deterministic for a fixed grid+locale count, so call once. `gbl` is the global domain.
  proc haloBytesPerStep(const ref arr: [] ?eltType, gbl): int {
    var cells = 0;
    coforall loc in Locales with (+ reduce cells) do on loc {
      const ls   = arr.localSubdomain();
      const recv = ls.expand(1)[gbl];
      cells += recv.size - ls.size;
    }
    return cells * (numBits(eltType) / 8);
  }

  // Aggregate GASNet op counts across all locales (cumulative since startCommDiagnostics).
  // `on` is a reserved word, so the execute_on count is named `ons`.
  record commSnapshot {
    var put = 0, get = 0, ons = 0, amo = 0;
  }
  proc currentComm(): commSnapshot {
    const d = getCommDiagnostics();
    var s: commSnapshot;
    for l in LocaleSpace {
      s.put += (d[l].put + d[l].put_nb): int;
      s.get += (d[l].get + d[l].get_nb): int;
      s.ons += (d[l].execute_on + d[l].execute_on_fast + d[l].execute_on_nb): int;
      s.amo += d[l].amo: int;
    }
    return s;
  }
}

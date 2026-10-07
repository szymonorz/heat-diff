# Logi pomiarowe

Logi czasu działania programu `heat3d` na **klastrze Pionier** (9 identycznych węzłów, Intel Core
i7-12700K 12c/20t, 32 GiB, Ethernet 1 Gbit/s, jednorodne Ubuntu), zebrane skryptem
`scripts/bench.sh` przez **kanał mpi**. Każdy log nosi nazwę `<binary>-<YYYYmmdd-HHMMSS>.log` i jest
samoopisujący: otwiera go wiersz `[cfg] threadsPerLocale(requested)=N numLocales=M`, zapisuje czasy
`updateFluff` / `compute` / `save` per krok, a kończy wierszami `Execution time:` oraz
`final field: … sum=…`. Przemiatany parametr odtwarza się z tej zawartości, więc nie pojawia się w
nazwie pliku. `analyze_logs.py` zamienia te katalogi na wykresy pudełkowe i wykresy metryk
pochodnych; `aggregate_bench.py` produkuje `RESULTS.tsv` / `summary.txt` dla każdej serii.

Przyrostek `-clean` oznacza, że usunięto przebiegi odstające lub przerwane, więc konfiguracja może
mieć nieco mniej niż nominalne dziesięć powtórzeń.

**Wspólne parametry** (o ile uwaga przy katalogu nie mówi inaczej): Chapel 2.9.0, backend C
(`CHPL_LLVM=none`), `--alpha 0.25`, `--numSteps 100`, brak wejścia-wyjścia kadrów (`--dumpEvery` >
liczba kroków) oraz **dziesięć powtórzeń na konfigurację** (praca raportuje medianę). Węzły Pionier
udostępniają 20 wątków sprzętowych, ale qthreads ogranicza locale do **16** (osiem rdzeni P, 2-drożny
SMT), więc żądana liczba 20 działa jako 16 efektywnych wątków.

Wszystkie poniższe przebiegi uruchamiane są z węzła głównego w `--mode cluster`; `bench.sh` czyta
kanał i listę węzłów z pliku `run-env.sh` wygenerowanego przez `compile-and-distribute.sh`
(`--run-env <install>/run-env.sh --workdir <install>`, pominięte tu dla zwięzłości).

## logs-cpu-clean — skalowanie wątkowe

Liczba wątków na locale przemiatana `1 2 4 8 16` przy stałej siatce 1000³ na wszystkich 9 węzłach.

```bash
./scripts/bench.sh --mode cluster --suite threads --cube-base 1000 --threads "1 2 4 8 16"
```

## logs-cube-size-clean — przemiatanie rozmiaru kostki

Krawędź siatki przemiatana `125 250 500 1000 2000` na wszystkich 9 węzłach przy domyślnej liczbie
wątków (20 → 16).

```bash
./scripts/bench.sh --mode cluster --suite cube --cubes "125 250 500 1000 2000"
```

## logs-node-scaling-clean — skalowanie węzłowe (locale)

Liczba locale przemiatana `1 … 9` przy stałej siatce 1000³ i domyślnej liczbie wątków (20 → 16).

```bash
./scripts/bench.sh --mode cluster --suite nodes --cube-base 1000 --nodes "1 2 3 4 5 6 7 8 9"
```

## logs-test-clean — jednowęzłowe skalowanie wątkowe

Jednolokalowe skalowanie wątkowe: 1 locale, 1000³, **10 kroków**, wątki `1 2 4 8 16`. To dane stojące
za wykresem jednowęzłowego skalowania wątkowego (`thesis/figures/threads_1000.pdf`, rysowanym przez
`plot_threads_1000.py`).

```bash
./scripts/bench.sh --mode cluster --suite threads --nodes-fixed 1 \
    --cube-base 1000 --threads "1 2 4 8 16" --steps 10
```

## logs-llvm — porównanie backendów kompilatora

Dwie binarki tego samego programu uruchomione na wszystkich 9 węzłach przy 100³, 100 kroków, 10
powtórzeń: `none/` to backend C (`CHPL_LLVM=none`), `llvm/` to backend LLVM (`CHPL_LLVM=system`,
LLVM 19.1.7). Zbuduj drugą binarkę z `--llvm system` (zobacz README repozytorium), a następnie:

```bash
./scripts/bench.sh --mode cluster --suite llvm --cube-base 100 \
    --llvm-binaries "heat3d_none:none heat3d_llvm:llvm"
```

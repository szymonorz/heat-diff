# Od początku do końca: budowa, dystrybucja i uruchomienie heat3d na klastrze

Przewodnik po budowie i dystrybucji Chapela, kompilacji i dystrybucji programu `heat3d` oraz
uruchomieniu go na całym klastrze, w całości sterowany skryptami z repozytorium. Wszystko dzieje się
z **węzła głównego**, na którym to repozytorium jest sklonowane (więc `scripts/`, `src/` i `data/`
są dostępne).

Klaster docelowy: 9 identycznych węzłów (Intel Core i7-12700K, 12c/20t, 32 GiB, Ethernet 1 Gbit/s,
jednorodne Ubuntu), dostępnych przez SSH na porcie 22. Ponieważ sieć to pojedyncze łącze 1 Gbit/s,
użyj **kanału mpi** (`--conduit mpi`): kanał udp przerywa działanie błędem `ECONGESTION` pod
obciążeniem typu incast (wiele do jednego) przy wymianie warstw brzegowych w skali. Węzły są
jednorodne, więc jedna budowa na węźle głównym działa wszędzie.

Ustawienia powłoki używane w całym przewodniku (dostosuj użytkownika i ścieżkę instalacji do swojego
konta):

```bash
NODE_USER=pionier
INSTALL_DIR=/home/pionier/chapel        # ta sama sciezka bezwzgledna na kazdym wezle
```

Ścieżka instalacji musi być **identyczna na wszystkich węzłach**: warstwa uruchomieniowa Chapela
wpisuje ją w `rpath` binarek, więc rozbieżność psuje ładowanie bibliotek współdzielonych przy
starcie.

## 1. Pliki z adresami węzłów

`distribute-chapel.sh` wysyła zestaw narzędzi na węzły **robocze**; `compile-and-distribute.sh`
potrzebuje **wszystkich** węzłów, master jako pierwszy.

```bash
# tylko robocze (kazdy wezel oprocz mastera)
printf 'lab8-2\nlab8-3\nlab8-4\nlab8-5\nlab8-6\nlab8-7\nlab8-8\nlab8-9\n' > hosts.txt

# wszystkie wezly, master jako pierwszy
printf 'lab8-1\nlab8-2\nlab8-3\nlab8-4\nlab8-5\nlab8-6\nlab8-7\nlab8-8\nlab8-9\n' > hosts-both.txt
```

## 2. Budowa i dystrybucja Chapela (+ MPICH)

Buduje Chapel 2.9.0 i MPICH 4.2.3 ze źródeł na masterze i wysyła oba na każdy węzeł roboczy pod
`$INSTALL_DIR`. **~20–40 min** za pierwszym razem; ponowne uruchomienia pomijają budowę MPICH.

```bash
CHAPEL_SSH_USER=$NODE_USER \
  bash scripts/distribute-chapel.sh --conduit mpi -f hosts.txt -d "$INSTALL_DIR"
```

Aby wbudować backend LLVM zamiast domyślnego backendu C, dodaj
`--llvm system --llvm-config /usr/bin/llvm-config-<N>` (tylko węzeł budujący potrzebuje pakietów
deweloperskich LLVM, zobacz krok 6).

## 3. Kompilacja i dystrybucja programu

Kompiluje `heat3d` wraz z post-procesorem `aggregate3d` i rozsyła binarki na wszystkie węzły. Użyj
**tych samych `--conduit`/`--llvm`** co w kroku 2 oraz `-d` różnego od roboczej kopii repozytorium,
aby katalog instalacji i źródła nigdy się nie nakładały.

```bash
CHAPEL_SSH_USER=$NODE_USER \
  bash scripts/compile-and-distribute.sh --conduit mpi -f hosts-both.txt -d "$INSTALL_DIR"
```

Oba pliki, `<bin>` i `<bin>_real`, są kopiowane na każdy węzeł (uruchomienie wielolokalowe wymaga
obu). Ten krok generuje też w `$INSTALL_DIR` wspólne środowisko launchera **`run-env.sh`** oraz
wrappery `run-heat3d.sh` i `aggregate-heat3d.sh`. Powtarzaj ten krok za każdym razem, gdy zmienia
się `src/*.chpl`.

## 4. Uruchomienie na węzłach

Wygenerowany wrapper ustawia środowisko launchera dla kanału i uruchamia program na wszystkich
locale. Przekaż `--dumpDir` jako ścieżkę **bezwzględną**, ponieważ węzły robocze mają inny katalog
roboczy:

```bash
cd "$INSTALL_DIR"
CHPL_RT_NUM_THREADS_PER_LOCALE=16 ./run-heat3d.sh \
    --nx=1000 --ny=1000 --nz=1000 --numSteps=100 --dumpDir="$INSTALL_DIR/frames"
```

Każde locale zapisuje tylko swoją warstwę na swój lokalny dysk. Scal warstwy i (opcjonalnie)
wyrenderuj film później:

```bash
./aggregate-heat3d.sh --render=true
```

Kadry są domyślnie kompresowane gzipem; na dużej siatce z wieloma krokami przerzedź je przez
`--dumpEvery=N` (a następnie przekaż agregatorowi `--numFrames = numSteps/N`), aby nie zapełnić
dysku węzła (`ENOSPC`).

## 5. Serie pomiarowe

`bench.sh` prowadzi rodziny testów z pracy (skalowanie wątkowe, przemiatanie rozmiaru kostki,
skalowanie węzłowe oraz porównanie backendów kompilatora) i zapisuje, per seria, logi poszczególnych
przebiegów oraz `RESULTS.tsv` i `summary.txt`. Uruchom go na masterze w `--mode cluster`: wczytuje
`run-env.sh` z kroku 3 dla kanału i listy węzłów, a `-nl` zmienia samodzielnie w ramach przemiatania.

```bash
bash scripts/bench.sh --mode cluster \
     --run-env "$INSTALL_DIR/run-env.sh" --workdir "$INSTALL_DIR" \
     --suite threads,cube,nodes --cube-base 1000 --nodes "1 2 4 8 9" \
     --outdir "$INSTALL_DIR/bench-out"
```

Każdy przebieg jest powtarzany (`--reps`, domyślnie 10) i wykonywany sekwencyjnie. Logi noszą nazwy
`<binary>-<timestamp>.log`, zgodnie z tą samą konwencją co `data/logs-*`. `--dry-run` wypisuje
zaplanowane przebiegi bez wykonywania; `bash scripts/bench.sh --help` wymienia każdą flagę (kroki,
powtórzenia, alpha, listy wątków/kostek/węzłów, …).

## 6. Porównanie backendów kompilatora (opcjonalne)

LLVM to backend czasu kompilacji. Zbuduj drugą binarkę programu z backendem LLVM obok domyślnej
binarki z backendem C, a następnie uruchom serię `llvm`. Tylko **master** potrzebuje zainstalowanego
LLVM, bo wysłane binarki nie linkują `libLLVM`, więc węzły robocze uruchamiają je bez niego.

```bash
# jednorazowo: pakiety deweloperskie LLVM na masterze, glowna wersja w zakresie Chapel 2.9 (14-22)
sudo apt-get install -y llvm-16-dev clang-16 libclang-16-dev libclang-cpp16-dev

# przebuduj zestaw narzedzi Z backendem LLVM i rozeslij ponownie:
CHAPEL_SSH_USER=$NODE_USER \
  bash scripts/distribute-chapel.sh --conduit mpi --llvm system \
       --llvm-config /usr/bin/llvm-config-16 -f hosts.txt -d "$INSTALL_DIR-llvm"

# skompiluj program z backendem LLVM, pod odrebna nazwa:
CHAPEL_SSH_USER=$NODE_USER \
  bash scripts/compile-and-distribute.sh --conduit mpi --llvm system \
       --llvm-config /usr/bin/llvm-config-16 -o heat3d_llvm \
       -f hosts-both.txt -d "$INSTALL_DIR-llvm"

# porownaj oba backendy (zbuduj tez heat3d z backendem C do tego samego katalogu):
bash scripts/bench.sh --mode cluster --run-env "$INSTALL_DIR-llvm/run-env.sh" \
     --workdir "$INSTALL_DIR-llvm" --suite llvm \
     --llvm-binaries "heat3d:none heat3d_llvm:llvm" --outdir "$INSTALL_DIR-llvm/bench-llvm"
```

Użyj odrębnego `-d` per backend (`none`/`system`), aby obie instalacje współistniały. Na programie
3D backend LLVM daje tylko niewielki zysk na pętli obliczeniowej i zero na komunikacji, ponieważ
stencil jest ograniczony przepustowością pamięci, a czas działania wielowęzłowego jest zdominowany
przez wymianę warstw brzegowych.

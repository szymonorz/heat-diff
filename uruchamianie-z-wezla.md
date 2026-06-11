# Uruchamianie z węzła klastra — komendy (copy-paste)

Założenie: jesteś zalogowany na **węźle głównym** klastra jako `pionier`, węzły
komunikują się po SSH na porcie `22`, a skrypty (`build-chapel.sh`,
`distribute-chapel.sh`, `compile-and-distribute.sh`, `chplconfig`) i katalog `src/`
leżą w katalogu domowym (`~`).

## 0. Zmienne — ustaw raz na początku sesji

```bash
export NODE_USER=pionier
export INSTALL_DIR=/home/pionier/szyorz/chapel      # tu wyląduje podkatalog chapel-2.7.0
export CHPL_HOME=$INSTALL_DIR/chapel-2.7.0          # faktyczne CHPL_HOME
export SSH_PORT=22
```

## 1. Plik hostów

```bash
# distribute-chapel.sh: tylko węzły docelowe (workery)
printf '10.0.0.2\n' > ~/hosts.txt

# compile-and-distribute.sh (dla -nl 2): WSZYSTKIE węzły, główny jako pierwszy
printf '10.0.0.1\n10.0.0.2\n' > ~/hosts-both.txt
```

## 2. Budowa + dystrybucja Chapela — `distribute-chapel.sh`

```bash
mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"
cp ~/chplconfig .                                   # CHPL_COMM=gasnet, CHPL_LLVM=none
CHAPEL_SSH_USER=$NODE_USER CHAPEL_SSH_PORT=$SSH_PORT \
  bash ~/distribute-chapel.sh -f ~/hosts.txt -d "$INSTALL_DIR"
# tylko rozesłanie gotowego archiwum (bez ponownej budowy):
# CHAPEL_SSH_USER=$NODE_USER CHAPEL_SSH_PORT=$SSH_PORT \
#   bash ~/distribute-chapel.sh -f ~/hosts.txt -d "$INSTALL_DIR" --skip-build
```

(Alternatywa bez dystrybucji — budowa tylko na tym węźle: `cd "$INSTALL_DIR" && bash ~/build-chapel.sh`.)

## 3. Kompilacja + dystrybucja programu — `compile-and-distribute.sh`

Uruchamiana z podkatalogu (żeby kopiowanie „na siebie" do `$INSTALL_DIR` nie nadpisało
świeżej binarki); `-d` ten sam co przy Chapelu (bo z niego wyprowadzane jest `CHPL_HOME`
w skryptach uruchomieniowych):

```bash
mkdir -p ~/prog-build && ln -sfn ~/src ~/prog-build/src && cp ~/compile-and-distribute.sh ~/prog-build/
cp ~/hosts-both.txt ~/prog-build/
cd ~/prog-build
source "$CHPL_HOME/util/setchplenv.bash"
CHAPEL_SSH_USER=$NODE_USER CHAPEL_SSH_PORT=$SSH_PORT \
  bash compile-and-distribute.sh -f hosts-both.txt -d "$INSTALL_DIR"
# dopilnuj, by węzeł główny miał binaria w $INSTALL_DIR:
cp -f heat3d heat3d_real heat3d-swap heat3d-swap_real aggregate3d aggregate3d_real "$INSTALL_DIR"/
```

## 4. Uruchomienie solvera (`-nl 2`)

Wygenerowane skrypty (powstają w `$INSTALL_DIR`):

```bash
cd "$INSTALL_DIR"
./run-heat3d.sh       --nx=100 --ny=100 --nz=100 --numSteps=100
./run-heat3d-swap.sh  --nx=100 --ny=100 --nz=100 --numSteps=100
./aggregate-heat3d.sh --nx=100 --ny=100 --nz=100 --numFrames=100
```

Ze **śledzeniem pamięci** (obie flagi naraz — `--trackMem=true` wypisuje `[mem] ...`,
`--memTrack=true` włącza w runtime'cie liczenie `memoryUsed()`):

```bash
cd "$INSTALL_DIR"
./run-heat3d.sh --nx=100 --ny=100 --nz=100 --numSteps=100 --trackMem=true --memTrack=true
```

Nie trzeba nic zmieniać w samym `run-heat3d.sh` — kończy się on linią `./heat3d -nl <N> "$@"`,
więc wszystkie argumenty podane po nazwie skryptu są przekazywane dalej do binarki. Obie flagi
(`--trackMem` = config programu, `--memTrack` = flaga runtime'u Chapela) trafiają więc do `heat3d`.

Uruchomienie „ręczne" (alternatywa):

```bash
source "$CHPL_HOME/util/setchplenv.bash"
export GASNET_SSH_SERVERS="10.0.0.1 10.0.0.2"
export GASNET_MASTERIP=10.0.0.1
export CHPL_RT_NUM_THREADS_PER_LOCALE=$(nproc)
cd "$INSTALL_DIR"
./heat3d -nl 2 --nx=100 --ny=100 --nz=100 --numSteps=100 --dumpDir=frames
# ze śledzeniem pamięci:
./heat3d -nl 2 --nx=100 --ny=100 --nz=100 --numSteps=100 --dumpDir=frames --trackMem=true --memTrack=true
```

## Uwagi

- **`CHPL_HOME` = `$INSTALL_DIR/chapel-2.7.0`** — oba skrypty zawsze dodają podkatalog
  `chapel-2.7.0`; dlatego w `distribute-chapel.sh` i `compile-and-distribute.sh` używaj
  **tego samego `-d`**.
- **`src/` musi leżeć obok `compile-and-distribute.sh`** — `-d` dotyczy tylko miejsca
  instalacji na węzłach, nie lokalizacji źródeł.
- `distribute-chapel.sh` buduje w bieżącym katalogu (`$(pwd)/chapel-2.7.0`) — stąd
  `cd "$INSTALL_DIR"` przed uruchomieniem, by węzeł główny też miał Chapela pod tą ścieżką.
- Opcjonalnie `-o NAZWA` zmienia nazwę binarki (domyślnie `heat3d`).
- `setup-vm.sh` / `start-vm.sh` / `start-cluster.sh` są **po stronie hosta** (tworzą węzły)
  i nie uruchamia się ich z węzła klastra.

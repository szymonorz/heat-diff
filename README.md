# Symulacje przewodnictwa ciepła w języku Chapel

Programy rozwiązujące równanie przewodnictwa ciepła metodą różnic skończonych w 1D, 2D i 3D,
napisane w języku [Chapel](https://chapel-lang.org/), z równoległością na pamięci rozproszonej
poprzez GASNet.

## Symulacje

### 1D (`src/1d.chpl`)

Rozwiązuje jednowymiarowe równanie przewodnictwa ciepła na rozproszonej dziedzinie `BlockDist`.
Na końcach pręta umieszczone są dwa gorące obszary.

| Parametr | Domyślna | Opis |
|-----------|---------|-------------|
| `n` | 20 | Liczba punktów siatki |
| `numSteps` | 100 | Kroki czasowe |
| `alpha` | 0.25 | Współczynnik dyfuzji |

### 2D (`src/2d.chpl`)

Rozwiązuje dwuwymiarowe równanie przewodnictwa ciepła na dziedzinie `StencilDist` z konfigurowalnym
źródłem ciepła w kształcie radiatora (płyta bazowa z żebrami).

| Parametr | Domyślna | Opis |
|-----------|---------|-------------|
| `nx`, `ny` | 50 | Wymiary siatki |
| `numSteps` | 100 | Kroki czasowe |
| `alpha` | 0.25 | Współczynnik dyfuzji |
| `heatSourceX`, `heatSourceY` | środek | Położenie źródła ciepła |
| `heatSourceTemp` | 2.0 | Temperatura źródła ciepła |
| `debug` | false | Wypisywanie diagnostyki komunikacji GASNet |

### 3D (`src/3d.chpl`)

Rozwiązuje trójwymiarowe równanie przewodnictwa ciepła na dziedzinie `StencilDist` z gorącą warstwą
wzdłuż jednej ze ścian. W każdym kroku każde locale zapisuje **tylko swój własny blok** do lokalnego
zrzutu binarnego (`dumpDir/frame_<step>_loc_<id>.bin`), bez scalania danych i bez renderowania na
ścieżce krytycznej obliczeń. Renderowanie odbywa się później, w `src/aggregate3d.chpl`, czyli
jednolokalowym post-procesorze, który składa zrzuty i wykorzystuje renderer wokseli z modułu
`ImageUtils` (rzut perspektywiczny z krawędziowym szkieletem).

| Parametr | Domyślna | Opis |
|-----------|---------|-------------|
| `nx`, `ny`, `nz` | 20 | Wymiary siatki |
| `numSteps` | 100 | Kroki czasowe (jeden zrzucany kadr na krok) |
| `alpha` | 0.25 | Współczynnik dyfuzji |
| `hotThickness` | 2 | Grubość gorącej warstwy |
| `dumpDir` | frames | Katalog zrzutów per locale (tworzony na każdym węźle) |
| `debug` | false | Wypisywanie diagnostyki komunikacji GASNet |

Wariant ping-pong, `src/3d_pingpong.chpl`, jest identyczny poza tym, że używa naprzemiennych ról
buforów (`writeToU = step%2==1`) zamiast zamiany `un <=> u`. Jest to wariant odniesienia,
nieużywany w pomiarach.

Opcje renderera 3D (moduł `ImageUtils`):

| Parametr | Domyślna | Opis |
|-----------|---------|-------------|
| `-sImageUtils.render` | false | Włączenie wyjścia MP4 |
| `movieName` | heat.mp4 | Nazwa pliku wyjściowego (podaj `--movieName=heat3d.mp4`, aby zachować starą nazwę) |
| `imageH`, `imageW` | 512 | Rozdzielczość kadru |
| `camDist` | 2.0 | Odległość kamery |
| `rotX`, `rotY` | -0.5, 0.0 | Obrót kamery |
| `pointSize` | 3 | Promień dylatacji woksela |
| `cubeScale` | 1.0 | Skala wyświetlania sześcianu |

## Uwagi o wydajności

### Zamiana tablic (`un <=> u`) jest O(1), a nie kopiowaniem

Program 3D (`src/3d.chpl`) w każdym kroku zamienia bufory przez `un <=> u`. Wariant ping-pong
(`src/3d_pingpong.chpl`) unika tej zamiany per krok, naprzemiennie przydzielając role buforów.
Okazuje się, że zamiana **nie** stanowi istotnego kosztu. Operator zamiany tablic w języku Chapel
(`operator <=>` w `$CHPL_HOME/modules/internal/ChapelArray.chpl`) najpierw próbuje
`doiOptimizedSwap`, który zamienia wewnętrzne **wskaźniki danych tablic w czasie O(1)**. Kopiowanie
element po elemencie pętlą `forall` o złożoności O(N) jest tylko ścieżką zapasową dla rozkładów,
które nie implementują wariantu zoptymalizowanego, a `StencilDist` (podobnie jak `BlockDist`) go
implementuje. Zamiana nie przenosi więc żadnych danych masowych i nie wykonuje komunikacji, a
jedynie przepina wskaźniki lokalnych buforów każdego locale.

Ilość przenoszonych danych jest zatem O(1) w obu wariantach. Oba reżimy różnią się jednak po
przekroczeniu granicy locale, ponieważ `doiOptimizedSwap` uruchamia `coforall loc in Locales do on
loc { ... }`, aby zamienić wskaźnik każdego locale, a ta cross-lokalowa klauzula on-clause i bariera
per krok nie są darmowe na sieci o wysokim opóźnieniu:

| Konfiguracja | koszt zamiany / krok |
|---|---|
| Jedno locale, 120³, `--fast` | ≈ 3 µs (≈0.1% czasu obliczeń) |

Zamiana nie przenosi danych masowych w żadnej skali. Między locale `doiOptimizedSwap` uruchamia
jednak per krok `coforall loc in Locales do on loc { ... }`, aby zamienić wskaźnik każdego locale,
toteż wariant ping-pong (`3d_pingpong.chpl`) unika tego drobnego kroku koordynacji między locale.
Mimo to na klastrze 1 Gbit/s czas rzeczywisty per krok jest zdominowany przez `updateFluff` (wymiana
warstw brzegowych) i zrzut danych, przez co zamiana i tak pozostaje najmniejszym składnikiem.

> Uwaga: kanał GASNet **udp** przerywa działanie błędem `ECONGESTION` przy dużych wymianach warstw
> brzegowych pod obciążeniem typu incast (wiele do jednego) lub przy jakichkolwiek stratach pakietów
> (np. 1000³ na 9 węzłach 1 Gb ginie w kroku 1). Odporną poprawką jest **kanał mpi**
> (`--conduit mpi`, zobacz niżej): przenosi komunikaty aktywne przez MPI/TCP, więc przeciążone lub
> zawodne łącze stosuje kontrolę przepływu zamiast przerwania. Na czystej sieci oba kanały działają
> w granicach szumu względem siebie.

## Wymagania wstępne

- Chapel 2.9.0 (zbudowany z `CHPL_COMM=gasnet`; domyślnie `CHPL_LLVM=none`, albo `system`/`bundled`
  przez `--llvm`, zobacz niżej)
- Narzędzia do budowy: `gcc g++ make m4 perl python3 cmake wget` + `gmp.h` (nie zakłada się żadnego
  menedżera pakietów, skrypty sprawdzają to i podają polecenie instalacji dla Twojej dystrybucji)
- ffmpeg (do renderowania wideo)
- Dla `--conduit mpi`: nic dodatkowego, MPICH jest budowany ze źródeł i rozsyłany automatycznie

## Budowa, dystrybucja i uruchomienie na klastrze (`--conduit udp|mpi`)

Jedna flaga steruje całym potokiem. `udp` (domyślny) jest szybki na czystej sieci LAN; `mpi`
przetrwa straty pakietów i incast przy skalowaniu (zobacz uwagę wyżej).

```bash
# 1. Zbuduj Chapel + rozeslij skompilowany katalog na kazdy wezel z pliku hostfile.
#    Klaster jest jednorodny, wiec jedna budowa na dowolnym wezle dziala wszedzie.
#    --conduit mpi dodatkowo automatycznie buduje MPICH (ze zrodel) i wysyla go na wszystkie wezly.
./scripts/distribute-chapel.sh                -f hosts.txt -d /home/pionier/chapel
./scripts/distribute-chapel.sh --conduit mpi  -f hosts.txt -d /home/pionier/chapel-mpi

# 2. Skompiluj heat3d, rozeslij binarki i wygeneruj launcher uruchomieniowy swiadomy kanalu.
#    Hostfile wymienia WSZYSTKIE wezly, master jako pierwszy (jedno locale na wezel dla 1000^3 na realnym sprzecie).
./scripts/compile-and-distribute.sh                -f hosts-both.txt -d /home/pionier/chapel
./scripts/compile-and-distribute.sh --conduit mpi  -f hosts-both.txt -d /home/pionier/chapel-mpi

# 3. Uruchom przez wygenerowany launcher (ustawia wlasciwe srodowisko per kanal):
#    udp -> GASNET_SSH_SERVERS;  mpi -> mpirun + wrapper interfejsu per ranga.
/home/pionier/chapel-mpi/run-heat3d.sh --nx=1000 --ny=1000 --nz=1000 --numSteps=100
```

`-d` musi być zgodne między oboma skryptami (i różne per kanał, aby instalacje udp/mpi współistniały).
`build-mpi.sh` i dystrybucja MPI są idempotentne (pomijane, jeśli już obecne), więc ponowne
uruchomienia są tanie. Systematyczne serie pomiarowe prowadzi `scripts/bench.sh` (zobacz niżej);
wygenerowany `run-<bin>.sh` uruchamia pojedynczą konfigurację.

### Backend kompilatora (`--llvm none|system|bundled`)

Domyślnie Chapel używa backendu C (`CHPL_LLVM=none`). Aby zamiast tego generować kod przez LLVM,
podaj `--llvm` do **obu** skryptów, `distribute-chapel.sh` (lub `build-chapel.sh`) oraz
`compile-and-distribute.sh`. Wartość musi być taka sama, tak samo jak dla `--conduit`:

- `none` — backend C (domyślny). LLVM nie jest nigdzie potrzebny.
- `system` — użyj zainstalowanego LLVM przez `llvm-config` (jego główna wersja musi mieścić się w
  zakresie wspieranym przez Chapel, 14–22 dla 2.9). Dodaj `--llvm-config /usr/bin/llvm-config-<N>`,
  jeśli jest wersjonowany. Pakiety deweloperskie LLVM potrzebne są **tylko na węźle budującym**
  (`llvm-N-dev clang-N libclang-N-dev libclang-cppN-dev`). LLVM jest zależnością czasu kompilacji,
  więc wysłane binarki programu **nie** linkują `libLLVM` i działają na węzłach roboczych bez niego.
- `bundled` — zbuduj LLVM ze źródeł w katalogu Chapel (duże i wolne), dla samowystarczalnego zestawu
  narzędzi, który nie potrzebuje systemowego LLVM nawet do uruchomienia `chpl`.

Instalacja systemowego LLVM (tylko na węźle budującym), wybierz główną wersję z zakresu (14–22 dla
Chapel 2.9):

```bash
# Fedora / RHEL (uzywa LLVM z dystrybucji, jesli jest w zakresie):
sudo dnf install llvm-devel clang-devel

# Debian / nowsze Ubuntu (jesli dystrybucja dostarcza wersje w zakresie):
sudo apt-get install -y llvm-16-dev clang-16 libclang-16-dev libclang-cpp16-dev

# Ubuntu 20.04 "focal" i starsze (LLVM z dystrybucji konczy sie na 12, za stary) -> wlasne repo APT LLVM.
# UWAGA: llvm.sh uruchamia sie jako root i dodaje repo APT + klucz podpisujacy; to oficjalny
#        instalator LLVM.org (https://apt.llvm.org). Tego potrzebuje tylko wezel budujacy.
wget https://apt.llvm.org/llvm.sh && chmod +x llvm.sh && sudo ./llvm.sh 16
sudo apt-get install -y llvm-16-dev clang-16 libclang-16-dev libclang-cpp16-dev
# nastepnie wskaz go Chapelowi (wersjonowany llvm-config):  --llvm-config /usr/bin/llvm-config-16
```

`libclang-cpp<N>-dev` łatwo przeoczyć, a bez niego `printchplenv` z Chapela kończy się błędem
„Could not find the clang library …/libclang-cpp.so". Sprawdź przez `llvm-config-<N> --version`.

```bash
# Przyklad: kanal mpi + systemowy LLVM 16 (wezel budujacy potrzebuje najpierw pakietow deweloperskich LLVM)
./scripts/distribute-chapel.sh     --conduit mpi --llvm system --llvm-config /usr/bin/llvm-config-16 \
                           -f hosts.txt      -d /home/pionier/chapel-mpi-llvm
./scripts/compile-and-distribute.sh --conduit mpi --llvm system --llvm-config /usr/bin/llvm-config-16 \
                           -f hosts-both.txt -d /home/pionier/chapel-mpi-llvm
```

Zmierzony wpływ na program 3D: LLVM daje tylko niewielki zysk (~3–5% na pętli obliczeniowej, zero
na komunikacji), ponieważ stencil jest ograniczony przepustowością pamięci; główna wersja LLVM nie
daje wiarygodnej różnicy. Użyj odrębnego `-d` per backend, aby instalacje `none`/`system`
współistniały.

## Serie pomiarowe (`bench.sh`)

`bench.sh` uruchamia rodziny testów z pracy z jednego konfigurowalnego punktu wejścia i zapisuje,
per seria, logi poszczególnych przebiegów oraz `RESULTS.tsv` i `summary.txt`
(mediana/średnia/min/max/odch. std.). Każdy przebieg wypisuje standardowy dla pracy nagłówek
`[cfg] threadsPerLocale(requested)=N numLocales=M`, więc logi konsumuje się tak samo jak istniejące
zbiory `data/logs-*`.

Serie (`--suite`, rozdzielone przecinkami lub `all`):

| seria | zmienna | ustalone |
|-------|--------|-------|
| `threads` | `--threads "1 2 4 8 16"` | `--cube-base`, `--nodes-fixed` |
| `cube` | `--cubes "125 250 500 1000"` | `--thread-fixed`, `--nodes-fixed` |
| `nodes` | `--nodes "1 2 …"` (klaster) | `--cube-base`, `--thread-fixed` |
| `llvm` | każda z `--llvm-binaries "ścieżka:etykieta …"` | `--cube-base`, `--thread-fixed`, `--nodes-fixed` |

Tryby (`--mode`): `local` uruchamia `./<binary> -nl 1` bezpośrednio; `cluster` uruchamia
wielolokalowo **na węźle głównym**, wczytując `run-env.sh` wygenerowany przez
`compile-and-distribute.sh` (jedyne źródło środowiska launchera, czyli kanał,
`MPIRUN_CMD`/wrapper interfejsu lub `GASNET_SSH_SERVERS`, oraz lista węzłów) i używając jego
pierwszych *n* węzłów, więc liczba węzłów zmienia się dowolnie. Wskaż ten plik przez `--run-env`
(domyślnie `<workdir>/run-env.sh`); `--chpl-home`/`--mpi-dir` działają tylko w trybie `local`.

Parametry to flagi nad domyślnymi wartościami pracy (`--steps 100`, `--reps 10`, `--alpha 0.25`,
`--dumpevery` duże = brak wejścia-wyjścia kadrów, …); `./scripts/bench.sh --help` wymienia je
wszystkie, a `--dry-run` wypisuje zaplanowane przebiegi bez wykonywania. `--binary` jest
**opcjonalne** (domyślnie `heat3d`, czyli to, co produkuje `compile-and-distribute.sh`); seria
`llvm` ignoruje je i używa `--llvm-binaries`.

```bash
# Podglad pelnego planu, bez uruchamiania:
./scripts/bench.sh --mode local --dry-run

# Serie lokalne na tym hoscie (jego swieze binarki to heat3d_none / heat3d_llvm):
./scripts/bench.sh --mode local --suite threads,cube,llvm --binary heat3d_none \
           --llvm-binaries "heat3d_none:none heat3d_llvm:llvm"

# Pelna macierz pracy na klastrze (uruchom na masterze), 1000^3 -- kanal/hosty z run-env.sh:
./scripts/bench.sh --mode cluster --run-env /home/pionier/.../chapel/run-env.sh \
           --workdir /home/pionier/.../chapel \
           --suite all --cube-base 1000 --nodes "1 2 4 8 9"
```

`bench.sh` jedynie *uruchamia* testy na już zbudowanych binarkach; backend kompilatora i kanał
wybiera się przy ich budowie (`distribute-chapel.sh` / `compile-and-distribute.sh --llvm …`).

## Kompilacja

```bash
export CHPL_HOME=~/chapel-2.9.0
source $CHPL_HOME/util/setchplenv.bash

cd src
chpl --main-module 3d 3d.chpl -o heat3d
chpl --main-module aggregate3d aggregate3d.chpl ImageUtils.chpl -o aggregate3d
chpl 1d.chpl ImageUtils.chpl -o heat1d
```

## Uruchamianie

Programy GASNet wymagają `-nl` (liczba locale) oraz `GASNET_SSH_SERVERS`:

```bash
export GASNET_SSH_SERVERS=localhost

# 1D
./heat1d -nl 1 --n=100 --numSteps=500 -sImageUtils.render=true

# 3D z renderowaniem
./aggregate3d --render=true --nx=30 --ny=30 --nz=30 --numFrames=50   # renderuje zrzucone kadry
```

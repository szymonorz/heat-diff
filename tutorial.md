# From-scratch 2-node Chapel cluster + heat3d run

End-to-end walkthrough: recreate two fresh QEMU VMs, build & distribute Chapel,
compile & distribute the `heat3d` program, and run it across 2 locales — driven
through the repo's provided scripts.

All commands run from the **dev host** unless marked otherwise. SSH settings reused
throughout:

```bash
KEY=~/qemu-vms/chapel-cluster/cluster_key
SSHOPT="-i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o BatchMode=yes"
```

Topology: **vm1** = master/build node (`10.0.0.1`, host port `2222`), **vm2** = worker
(`10.0.0.2`, host port `2223`). Inter-VM network is QEMU socket-multicast; `hosts.txt`
contains the worker IP `10.0.0.2`.

---

## 1. Kill any running VMs

```bash
kill $(cat ~/qemu-vms/chapel-cluster/vm1/qemu.pid) \
     $(cat ~/qemu-vms/chapel-cluster/vm2/qemu.pid)
```

## 2. Create fresh disks (reuse existing cloud-init seeds) and boot

```bash
CL=~/qemu-vms/chapel-cluster
BASE=~/qemu-vms/ubuntu2004-chapel/focal-server-cloudimg-amd64.img   # from setup-vm.sh

rm -f $CL/vm1/disk.qcow2 $CL/vm2/disk.qcow2 $CL/vm1/qemu.pid $CL/vm2/qemu.pid
for vm in vm1 vm2; do
  cp "$BASE" "$CL/$vm/disk.qcow2"
  qemu-img resize "$CL/$vm/disk.qcow2" 60G
done

bash start-cluster.sh
```

## 3. Wait for cloud-init to finish provisioning

```bash
ssh $SSHOPT -p 2222 chapel@localhost 'cloud-init status --wait'   # vm1
ssh $SSHOPT -p 2223 chapel@localhost 'cloud-init status --wait'   # vm2
```

> cloud-init reports `status: error` on these seeds — that's expected; it's caused by the
> three known bugs fixed in the next step. Everything essential (user, packages, network)
> is in place.

## 4. Fix the three known cloud-init seed bugs

**(a) Cluster private key not written** (the `write_files` module runs before the
`chapel` user exists, so inter-VM SSH has no key):

```bash
for port in 2222 2223; do
  scp $SSHOPT -P $port "$KEY" chapel@localhost:~/.ssh/id_ed25519
  ssh $SSHOPT -p $port chapel@localhost 'chmod 600 ~/.ssh/id_ed25519'
done
```

**(b) `/home/chapel` owned by root:**

```bash
for port in 2222 2223; do
  ssh $SSHOPT -p $port chapel@localhost 'sudo chown -R chapel:chapel /home/chapel'
done
```

**(c) `.bashrc` prints to stdout** (the `source setchplenv.bash` line — added later by
`distribute-chapel.sh` — corrupts `scp` and the GASNet worker spawn). Apply **after**
step 6 on both nodes:

```bash
for port in 2222 2223; do
  ssh $SSHOPT -p $port chapel@localhost \
    "sed -i '/setchplenv.bash/{/2>&1/!s/\$/ >\/dev\/null 2>\&1/}' ~/.bashrc"
done
```

Verify GASNet's SSH targets work from vm1 (both must succeed, silently):

```bash
ssh $SSHOPT -p 2222 chapel@localhost \
  'for h in 10.0.0.1 10.0.0.2; do ssh -o StrictHostKeyChecking=no -o BatchMode=yes $h hostname; done'
```

## 5. Install pip3 on vm1 (prereq for the cmake upgrade in distribute-chapel.sh)

Focal ships cmake 3.16; the script upgrades via `pip3 install cmake`, but the seed
doesn't install pip:

```bash
ssh $SSHOPT -p 2222 chapel@localhost 'sudo apt-get install -y python3-pip'
```

## 6. Stage the provided scripts + sources on vm1

```bash
R=/home/sorzechowski/schule/heat-diff
ssh $SSHOPT -p 2222 chapel@localhost 'mkdir -p ~/src'
# mpi flow needs build-mpi.sh (called by distribute-chapel --conduit mpi) and mpi-iface-wrap.sh
# (used by compile-and-distribute for the mpi launcher); bench.sh drives the suites in step 10.
scp $SSHOPT -P 2222 "$R/distribute-chapel.sh" "$R/build-chapel.sh" "$R/build-mpi.sh" \
                    "$R/compile-and-distribute.sh" "$R/mpi-iface-wrap.sh" "$R/bench.sh" \
                    "$R/hosts.txt" chapel@localhost:~/
scp $SSHOPT -P 2222 "$R/src/3d.chpl" "$R/src/3d_pingpong.chpl" \
                    "$R/src/ImageUtils.chpl" "$R/src/aggregate3d.chpl" chapel@localhost:~/src/
ssh $SSHOPT -p 2222 chapel@localhost 'chmod +x ~/*.sh'
```

## 7. Build & distribute Chapel (runs on vm1; builds locally, ships to vm2)

`hosts.txt` contains `10.0.0.2`. This builds Chapel 2.9.0 + MPICH from source on vm1 and ships
both to vm2. Use the **mpi conduit** (`--conduit mpi`): the udp conduit `ECONGESTION`-aborts on
the QEMU socket-multicast link. Add `--llvm system|bundled` (and `--llvm-config PATH`) here to
bake in the LLVM backend; default is the C backend. **~20–40 min.** Run from `~` so vm1's own
tree lands at `/home/chapel/chapel-2.9.0` (same path as vm2).

```bash
ssh $SSHOPT -p 2222 chapel@localhost \
  'cd ~ && CHAPEL_SSH_USER=chapel CHAPEL_SSH_PORT=22 \
     bash distribute-chapel.sh --conduit mpi -f hosts.txt -d /home/chapel -m /home/chapel/mpi'
```

Then apply fixup **4(c)** (it silences the `.bashrc` line this step just added).

## 8. Compile & distribute the program

Run `compile-and-distribute.sh` from a **build subdir** (so the master's self-copy uses a
distinct path and can't truncate the freshly compiled binary) with a **2-node hostfile**, master
first (so the generated run scripts get `MASTER=10.0.0.1`, `NUM_LOCALES=2`). Use the **same
`--conduit`/`--llvm`** as step 7. `mpi-iface-wrap.sh` must sit beside the script (the mpi launcher
uses it):

```bash
ssh $SSHOPT -p 2222 chapel@localhost 'bash -s' <<'REMOTE'
mkdir -p ~/prog-build && ln -sfn ~/src ~/prog-build/src
cp ~/compile-and-distribute.sh ~/mpi-iface-wrap.sh ~/prog-build/
printf '10.0.0.1\n10.0.0.2\n' > ~/prog-build/hosts-both.txt
cd ~/prog-build
CHAPEL_SSH_USER=chapel CHAPEL_SSH_PORT=22 \
  bash compile-and-distribute.sh --conduit mpi -f hosts-both.txt -d /home/chapel -m /home/chapel/mpi
# ensure the master's /home/chapel has the fresh binaries (build subdir -> install dir):
cp -f ~/prog-build/heat3d ~/prog-build/heat3d_real \
      ~/prog-build/aggregate3d ~/prog-build/aggregate3d_real /home/chapel/
REMOTE
```

If the script's `scp` to vm2 failed (it does if 4(c) wasn't applied yet), re-push the
binaries — **both `heat3d` AND `heat3d_real`**, every node needs both for `-nl 2`:

```bash
ssh $SSHOPT -p 2222 chapel@localhost \
  'scp -o StrictHostKeyChecking=no ~/heat3d ~/heat3d_real \
       ~/aggregate3d ~/aggregate3d_real 10.0.0.2:/home/chapel/'
```

This also generates, in `/home/chapel`, the shared launcher env **`run-env.sh`** plus
`run-heat3d.sh` and `aggregate-heat3d.sh` (the run script sources `run-env.sh`).

## 9. Run heat3d across 2 locales

```bash
# mpi conduit sustains the run (no ECONGESTION), so no GASNET_* buffer/timeout tuning is needed.
ssh $SSHOPT -p 2222 chapel@localhost \
  'bash ~/run-heat3d.sh --nx=100 --ny=100 --nz=100 --numSteps=100 \
       --dumpDir=/home/chapel/out100 --trackMem=true --memTrack=true'
```

Each locale writes only its own slab to its **local** disk (`out100/frame_<step>_loc_<id>.bin`):
vm1 holds the `loc_0` frames, vm2 the `loc_1` frames — no gather.

## 10. Run the benchmark suites (`bench.sh`)

`bench.sh` drives the thesis benchmark families (thread scaling, cube-size sweep, node scaling,
and the compiler-backend comparison) from one place and writes, per suite, the logs plus a
`RESULTS.tsv` and `summary.txt`. Run it **on vm1** in `--mode cluster`: it sources the
`run-env.sh` that step 8 generated (conduit + host list + launcher env), so it varies `-nl`
across the sweep on its own.

```bash
# stage bench.sh on vm1 (once)
scp $SSHOPT -P 2222 "$R/bench.sh" chapel@localhost:~/

# run the matrix on the 2-VM cluster; conduit + hosts come from /home/chapel/run-env.sh
ssh $SSHOPT -p 2222 chapel@localhost 'bash ~/bench.sh \
     --mode cluster --run-env /home/chapel/run-env.sh --workdir /home/chapel \
     --suite threads,cube,nodes --cube-base 500 --nodes "1 2" \
     --binary heat3d --outdir /home/chapel/bench-out'
```

`--dry-run` prints the planned runs first; `bash ~/bench.sh --help` lists every flag (steps, reps,
alpha, thread/cube/node lists, etc.). To compare compiler backends, build a second binary with
`--llvm system` (step 8) and add `--suite llvm --llvm-binaries "heat3d:none heat3d_llvm:llvm"`.
Pull results back with `scp -r ... chapel@localhost:/home/chapel/bench-out data/`.

> Selecting the compiler backend: `distribute-chapel.sh`, `build-chapel.sh` and
> `compile-and-distribute.sh` take `--llvm none|system|bundled` (default `none`) plus
> `--llvm-config PATH`. Only the build node needs LLVM installed; the shipped binaries run on
> workers without it. `bench.sh` itself only *runs* benchmarks, it does not build toolchains.

## 11. Add the LLVM backend to an existing (mpi, no-LLVM) build

LLVM is a compile-time backend, so you add it **without a from-scratch rebuild**: it slots a new
compiler config next to the existing `none` one, reusing MPICH, GASNet and the source tree. All on
the **build/master node** (vm1); workers are untouched (they run the shipped binary without LLVM).

```bash
# 0. (once) install LLVM dev packages -- a major version in Chapel 2.9's range (14-22):
ssh $SSHOPT -p 2222 chapel@localhost \
  'sudo apt-get install -y llvm-16-dev clang-16 libclang-16-dev libclang-cpp16-dev'   # focal: use apt.llvm.org

# 1. rebuild the toolchain to ADD the LLVM backend (incremental: MPICH + GASNet reused, ~10-20 min).
#    build-chapel.sh rebuilds locally only -- run it from the dir holding chapel-2.9.0 (/home/chapel):
ssh $SSHOPT -p 2222 chapel@localhost \
  'cd /home/chapel && bash ~/build-chapel.sh --conduit mpi --llvm system --llvm-config /usr/bin/llvm-config-16'

# 2. recompile + redistribute the program with the LLVM backend, under a new name:
ssh $SSHOPT -p 2222 chapel@localhost 'bash -s' <<'REMOTE'
cd ~/prog-build
CHAPEL_SSH_USER=chapel CHAPEL_SSH_PORT=22 \
  bash compile-and-distribute.sh --conduit mpi --llvm system --llvm-config /usr/bin/llvm-config-16 \
       -o heat3d_llvm -f hosts-both.txt -d /home/chapel -m /home/chapel/mpi
cp -f ~/prog-build/heat3d_llvm ~/prog-build/heat3d_llvm_real /home/chapel/
REMOTE
```

Notes:
- Use **`build-chapel.sh`** (local rebuild on the master), **not** `distribute-chapel.sh`: the
  workers never compile, so the LLVM toolchain is only needed on the build node. Re-ship the whole
  toolchain (`distribute-chapel.sh --llvm system`) only if you intend to compile on the workers.
- The `none` toolchain **and** its binary stay intact -- from now on you can compile either backend
  on demand (`compile-and-distribute.sh --llvm none|system`).
- `--llvm-config` is only needed for a versioned `llvm-config` (e.g. `llvm-config-16`); omit it if a
  plain in-range `llvm-config` is on `PATH`.
- Compare the two backends with
  `bench.sh ... --suite llvm --llvm-binaries "heat3d:none heat3d_llvm:llvm"`.

---


```bash
  distribute-chapel.sh — zbuduj Chapel (+MPICH) tu i rozdystrybuuj na węzły z hosts.txt
  CHAPEL_SSH_USER=chapel CHAPEL_SSH_PORT=22 \
    bash distribute-chapel.sh --conduit mpi -f hosts.txt -d /home/chapel -m /home/chapel/mpi \
         [--llvm system --llvm-config /usr/bin/llvm-config-16]   # backend LLVM (opcjonalnie)
  # tylko rozesłanie gotowego archiwum (bez ponownej budowy): dodaj --skip-build
  # (build-chapel.sh --conduit mpi ... buduje tylko lokalnie, bez dystrybucji)

  compile-and-distribute.sh — skompiluj program i rozdystrybuuj (te same --conduit/--llvm co wyżej)
  bash compile-and-distribute.sh --conduit mpi -f hosts-both.txt -d /home/chapel -m /home/chapel/mpi
  # generuje w -d: run-env.sh (wspólne środowisko launchera) + run-heat3d.sh + aggregate-heat3d.sh

  Wygenerowane skrypty uruchomieniowe (powstają w -d na węźle głównym)
  ./run-heat3d.sh       --nx=1000 --ny=1000 --nz=1000 --numSteps=100
  ./aggregate-heat3d.sh --nx=1000 --ny=1000 --nz=1000 --numFrames=100

  bench.sh — zestaw testów wydajności (uruchom na węźle głównym; conduit/węzły z run-env.sh)
  bash bench.sh --mode cluster --run-env /home/chapel/run-env.sh --workdir /home/chapel \
       --suite threads,cube,nodes --cube-base 1000 --nodes "1 2 4 8 9" --outdir /home/chapel/bench-out

  Uruchomienie „ręcznie" (alternatywa dla run-skryptu) — przez wspólne run-env.sh
  source /home/chapel/run-env.sh
  set_run_env 2                    # środowisko launchera dla 2 pierwszych węzłów
  cd /home/chapel
  ./heat3d -nl 2 --nx=1000 --ny=1000 --nz=1000 --numSteps=100 --dumpDir=/home/chapel/frames
```
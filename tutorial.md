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
scp $SSHOPT -P 2222 "$R/distribute-chapel.sh" "$R/compile-and-distribute.sh" \
                    "$R/chplconfig" "$R/hosts.txt" chapel@localhost:~/
scp $SSHOPT -P 2222 "$R/src/3d.chpl" "$R/src/3d_swap.chpl" \
                    "$R/src/Render3D.chpl" "$R/src/aggregate3d.chpl" chapel@localhost:~/src/
ssh $SSHOPT -p 2222 chapel@localhost 'chmod +x ~/*.sh'
```

## 7. Build & distribute Chapel (runs on vm1; builds locally, ships to vm2)

`hosts.txt` contains `10.0.0.2`. This builds Chapel 2.7.0 from source on vm1
(`CHPL_COMM=gasnet`, `CHPL_LLVM=none`) and distributes the archive to vm2.
**~20–40 min.**

```bash
ssh $SSHOPT -p 2222 chapel@localhost \
  'cd ~ && CHAPEL_SSH_USER=chapel CHAPEL_SSH_PORT=22 bash distribute-chapel.sh -f hosts.txt'
```

Then apply fixup **4(c)** (it silences the `.bashrc` line this step just added).

## 8. Compile & distribute the program

Run `compile-and-distribute.sh` from a **build subdir** (so the master's self-copy uses a
distinct path and can't truncate the freshly compiled binary) with a **2-node hostfile**
(so the generated run scripts get `MASTER=10.0.0.1`, `NUM_LOCALES=2`):

```bash
ssh $SSHOPT -p 2222 chapel@localhost 'bash -s' <<'REMOTE'
mkdir -p ~/prog-build
ln -sfn ~/src ~/prog-build/src
cp ~/compile-and-distribute.sh ~/prog-build/
printf '10.0.0.1\n10.0.0.2\n' > ~/prog-build/hosts-both.txt
cd ~/prog-build
source ~/chapel-2.7.0/util/setchplenv.bash >/dev/null 2>&1
CHAPEL_SSH_USER=chapel CHAPEL_SSH_PORT=22 bash compile-and-distribute.sh -f hosts-both.txt
# make sure the master's /home/chapel has the binaries (build dir -> install dir)
cp -f ~/prog-build/heat3d ~/prog-build/heat3d_real \
      ~/prog-build/heat3d-swap ~/prog-build/heat3d-swap_real \
      ~/prog-build/aggregate3d ~/prog-build/aggregate3d_real ~/
REMOTE
```

If the script's `scp` to vm2 failed (it does if 4(c) wasn't applied yet), re-push the
binaries — **all of `<bin>` AND `<bin>_real`**, every node needs both for `-nl 2`:

```bash
ssh $SSHOPT -p 2222 chapel@localhost \
  'scp -o StrictHostKeyChecking=no ~/heat3d ~/heat3d_real ~/heat3d-swap ~/heat3d-swap_real \
       ~/aggregate3d ~/aggregate3d_real 10.0.0.2:~/'
```

This also generates `~/run-heat3d.sh`, `~/run-heat3d-swap.sh`, and
`~/aggregate-heat3d.sh` on vm1.

## 9. Run heat3d across 2 locales

```bash
ssh $SSHOPT -p 2222 chapel@localhost 'bash -s' <<'REMOTE'
export GASNET_NETWORKDEPTH_TOTAL=8192 GASNET_REQUESTTIMEOUT_MAX=60000000
bash ~/run-heat3d.sh --nx=100 --ny=100 --nz=100 --numSteps=5 \
     --dumpDir=/home/chapel/out100 --trackMem=true --memTrack=true
REMOTE
```

Each locale writes only its own slab to its **local** disk (`out100/frame_<step>_loc_<id>.bin`):
vm1 holds the `loc_0` frames, vm2 the `loc_1` frames — no gather.

---


```bash
  build-chapel.sh — zbuduj Chapel lokalnie na tym węźle

  Bez argumentów; buduje ./chapel-2.7.0 w bieżącym katalogu (instaluje zależności przez sudo apt):
  bash build-chapel.sh

  distribute-chapel.sh — zbuduj Chapel tu i rozdystrybuuj na pozostałe węzły

  Buduje na bieżącym węźle i wysyła archiwum do węzłów z hosts.txt:
  CHAPEL_SSH_USER=chapel CHAPEL_SSH_PORT=22 bash distribute-chapel.sh -f hosts.txt
  # równoważnie z flagami:
  bash distribute-chapel.sh -f hosts.txt -u chapel -p 22
  # jeśli Chapel jest już zbudowany i chcesz tylko rozesłać archiwum:
  bash distribute-chapel.sh -f hosts.txt -u pionier -d /home/pionier/szyorz/chapel -p 22 --skip-build

  compile-and-distribute.sh — skompiluj program i rozdystrybuuj

  source /home/pionier/szyorz/chapel/chapel-2.7.0/util/setchplenv.bash
  bash compile-and-distribute.sh -f hosts.txt -u pionier -p 22 -d /home/pionier/szyorz/chapel
  
  Wygenerowane skrypty uruchomieniowe (powstają na węźle głównym)

  ./run-heat3d.sh       --nx=100 --ny=100 --nz=100 --numSteps=100
  ./run-heat3d-swap.sh  --nx=100 --ny=100 --nz=100 --numSteps=100
  ./aggregate-heat3d.sh --nx=100 --ny=100 --nz=100 --numFrames=100

  Uruchomienie programu „ręcznie" (alternatywa dla run-skryptu)

  source /home/pionier/szyorz/chapel/chapel-2.7.0/util/setchplenv.bash
  export GASNET_SSH_SERVERS="10.0.0.1 10.0.0.2"
  export GASNET_MASTERIP=10.0.0.1
  export CHPL_RT_NUM_THREADS_PER_LOCALE=$(nproc)
  ./heat3d -nl 2 --nx=100 --ny=100 --nz=100 --numSteps=100 --dumpDir=frames
```
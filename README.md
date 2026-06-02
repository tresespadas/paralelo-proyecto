# paralelo-proyecto

Learning-oriented sibling of `~/Work/proyecto/`. Spins up 3 Ubuntu 22.04 VMs on
libvirt and deploys a Kubernetes cluster with kubespray.

## Layout

| Node           | IP          | Custom user | Role          |
|----------------|-------------|-------------|---------------|
| `test-master`  | `10.0.1.10` | `master`    | control plane |
| `test-worker1` | `10.0.1.11` | `worker1`   | worker        |
| `test-worker2` | `10.0.1.12` | `worker2`   | worker        |

Network: libvirt bridge `red-prueba` on `10.0.1.0/24` with NAT.

## Bring up the VMs

```bash
vagrant up
```

Order of events (see `Vagrantfile`):

1. **Trigger** `scripts/network-check.sh` on the host — defines/starts the
   `red-prueba` libvirt network if it's missing or out of sync with
   `network/red-prueba.xml`.
2. **VM boot** — each node comes up sequentially (`VAGRANT_NO_PARALLEL = yes`).
3. **Provisioners** on each VM, in order:
   - `scripts/config.sh` — installs `vim`, `python3`, `pip`, `venv`, `git`.
   - `scripts/ssh-setup.sh <user>` — creates the custom user, grants
     passwordless sudo, installs the shared lab keypair for inter-node SSH.
4. **Trigger** `scripts/ssh-config.sh` on the host after `test-worker2` is up —
   writes host entries for `test-master`, `test-worker1`, `test-worker2` into
   `~/.ssh/config`, each mapped to its custom user.

After this you can `ssh test-master` (as `master`), etc.

## Deploy Kubernetes

The kubespray setup is registered as a provisioner but intentionally skipped on
`vagrant up` (it takes ~15 min). Run it on demand:

```bash
vagrant provision test-master --provision-with setup-kubespray
```

This executes `scripts/setup-kubespray.sh` inside `test-master` (as user
`master`) and:

1. Clones kubespray `v2.26.0` into `/home/master/kubespray`.
2. Creates a Python venv at `/home/master/kubespray-venv` and installs
   kubespray's `requirements.txt`.
3. Generates inventory `inventory/cluster-k8-paralelo/hosts.yml` with a
   per-host `ansible_user` (`master`, `worker1`, `worker2`).
4. Copies `inventory/sample/group_vars/` and switches the CNI to `flannel`.
5. Runs `ansible-playbook -i inventory/cluster-k8-paralelo/hosts.yml --become
   cluster.yml`.
6. Installs the admin kubeconfig at `/home/master/.kube/config`.

Verify once it finishes:

```bash
ssh test-master kubectl get nodes
ssh test-master kubectl get pods -A
```

## Tear down

```bash
vagrant destroy -f
```

The libvirt network and the shared lab keypair persist — `vagrant up` will
reuse them.

Paralel project for @~/Work/proyecto/ to cover knowledges gaps. Using Claude as a learning tool for asking the 'why's.

# To-Do's:
- [x] Understand custom network bridge from host to vagrant VM
- [x] Assign static IP on vagrant VM for custom network bridge
- [x] Find a way to access vagrant VM via GUI (virt-viewer / virt-manager with VNC)
- [x] Learn how provision script works
  - [x] Create a provision script for ssh authentication
- [x] Create 3 VMs for a kubernetes cluster and prepare a provision script for it
  - [x] Edit config.sh script to support it
  - [x] Understand everything from kubespray/inventory: hosts.yml, group_vars, ...
  - [x] What is .kube directory?
- [x] Learn how PV/PVC works
- [x] Setup Helm - Maybe add it to setup-kubespray.sh ?
  - [x] Check new addings to setup-kubespray.sh
- [x] Set up a wordpress for testing
- [x] Set up Grafana
- [ ] Set up custom Dashboard: monitoring and IDS logs
- [ ] Attack vulnerable DVWA
  - [ ] Reflect the attack on Grafana

# Nice-to-have:
- [ ] Improve console resolution (switch from cirrus/VNC to qxl/SPICE)

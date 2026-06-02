ENV['VAGRANT_NO_PARALLEL'] = 'yes'

Vagrant.configure("2") do |config|
  config.vm.box = "generic/ubuntu2204"

  # Synced folder explícito: el provider libvirt no lo activa de serie de forma
  # fiable, así que lo declaramos. rsync es el único modo que funciona sin
  # montar NFS ni virtiofs. Se dispara en `vagrant up` y en `vagrant rsync`.
  # Excluimos .git/.vagrant/disks para no empujar GB de qcow2 a las VMs.
  config.vm.synced_folder ".", "/vagrant", type: "rsync",
    rsync__exclude: [".git/", ".vagrant/", "disks/"]

  nodes = {
    "test-master"  => { "ip" => "10.0.1.10", "mac" => "52:54:00:00:01:10", "user" => "master" },
    "test-worker1" => { "ip" => "10.0.1.11", "mac" => "52:54:00:00:01:11", "user" => "worker1" },
    "test-worker2" => { "ip" => "10.0.1.12", "mac" => "52:54:00:00:01:12", "user" => "worker2" }
  }

  nodes.each do |name, info|
    config.vm.define name do |node|
      node.vm.hostname = name

      node.vm.network "private_network",
                      ip: info["ip"],
                      netmask: "255.255.255.0",
                      mac: info["mac"],
                      libvirt__network_name: "red-prueba",
                      libvirt__forward_mode: "nat",
                      libvirt__always_destroy: false

      node.vm.provider :libvirt do |libvirt|
        libvirt.memory = case name
                         when "test-master" then 4096
                         when "test-worker1" then 3072
                         else 2048
                         end
        libvirt.cpus = (name == "test-master" || name == "test-worker1") ? 2 : 1
        libvirt.mgmt_attach = false
      end

      node.vm.provision "shell" do |s|
        s.path = "scripts/config.sh"
      end

      node.vm.provision "shell" do |s|
        s.path = "scripts/ssh-setup.sh"
        s.args = [info["user"]]
      end

      if name == "test-master"
        node.vm.provision "setup-kubespray", type: "shell", run: "never" do |s|
          s.path = "scripts/setup-kubespray.sh"
          s.privileged = false
        end

        node.vm.provision "setup-lab", type: "shell", run: "never" do |s|
          s.path = "scripts/setup-lab.sh"
          s.privileged = false
        end

        node.vm.provision "setup-security", type: "shell", run: "never" do |s|
          s.path = "scripts/setup-security.sh"
          s.privileged = false
        end
      end
    end
  end

  config.trigger.before :up, only_on: "test-master" do |trigger|
    trigger.name = "[+] Comprobación de la red puente"
    trigger.run = { path: "scripts/network-check.sh" }
  end

  config.trigger.before :up, only_on: "test-master" do |trigger|
    trigger.name = "[+] Comprobación del almacenamiento: discos qcow2"
    trigger.run = { path: "scripts/create-disks.sh" }
  end

  config.trigger.after :up, only_on: "test-worker2" do |trigger|
    trigger.name = "[+] Configuración SSH las VMs"
    trigger.run = { path: "scripts/ssh-config.sh" }
  end

  config.trigger.after :up, only_on: "test-worker2" do |trigger|
    trigger.name = "[+] Conexión y montaje persistente de los discos"
    trigger.run = { path: "scripts/attach-disks.sh" }
  end
end

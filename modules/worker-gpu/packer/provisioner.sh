#wait for instance to be ready
sleep 30
sudo apt-get update
# sudo apt-get upgrade -y
#install docker etcd and build-essentials
sudo apt-get install -y etcd docker.io build-essential
#install rkt
wget https://raw.githubusercontent.com/coreos/rkt/master/scripts/install-rkt.sh
chmod +x install-rkt.sh
sudo ./install-rkt.sh

#prepare directories
sudo mkdir -p /etc/kubernetes/ssl
sudo mkdir -p /opt/bin
#download kubelet-wrapper and make executable
sudo curl -L -o /opt/bin/kubelet-wrapper https://raw.githubusercontent.com/coreos/coreos-overlay/master/app-admin/kubelet-wrapper/files/kubelet-wrapper
sudo chmod +x /opt/bin/kubelet-wrapper

#prepare for nvidia drivers
sudo apt-get install -y linux-image-extra-`uname -r` linux-headers-`uname -r` linux-image-`uname -r`
#get cuda8 and nvidia driver
wget https://developer.nvidia.com/compute/cuda/8.0/prod/local_installers/cuda_8.0.44_linux-run
wget http://de.download.nvidia.com/XFree86/Linux-x86_64/367.57/NVIDIA-Linux-x86_64-367.57.run
chmod +x *run
mkdir nvidia_installers
#install nvidia driver (-s silent -a accept license -Z disable noveau driver)
sudo ./NVIDIA-Linux-x86_64-367.57.run -s -Z -a
sudo update-initramfs -u

#extract cuda
./cuda_8.0.44_linux-run -extract=$PWD/nvidia_installers
#clean-up
rm -rf *run

#install cuda toolkit
cd nvidia_installers
sudo ./cuda-linux64-rel-8.0.44-21122537.run -noprompt

#clean-up
cd ../
rm -rf nvidia_installers

#export env variables
export PATH=/usr/local/cuda-8.0/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-8.0/lib64:$LD_LIBRARY_PATH
#make env variables available for normal user
echo export PATH=/usr/local/cuda-8.0/bin:\$PATH >> $HOME/.bashrc
echo export LD_LIBRARY_PATH=/usr/local/cuda-8.0/lib64:\$LD_LIBRARY_PATH >> $HOME/.bashrc

#make sure all devices are present
sudo mv /tmp/nv-devices /opt/bin/
sudo mv /tmp/nv-devices.service /etc/systemd/system/
sudo chmod +x /opt/bin/nv-devices
sudo systemctl daemon-reload
sudo systemctl start nv-devices.service
sudo systemctl enable nv-devices.service
#test cuda
#install cuda samples
#sudo ./cuda-samples-linux-8.0.44-21122537.run -noprompt -prefix=/usr/local/cuda-8.0/samples/ -cudaprefix=/usr/local/cuda-8.0
#cd /usr/local/cuda-8.0/samples/1_Utilities/deviceQuery
#sudo make deviceQuery

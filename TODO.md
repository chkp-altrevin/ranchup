## To Do
NOT a released version, there are some minor kinks working through. Welcome any feedback or thoughts. 

## Things being added or fixed
Listed by priority
- add port overrides and defaults for --kiosk and --config (example -p 8080:80 -p 8443:443 -p 6443:6443) 
- add custom file to match all flags
- add Proxmox k3s provisioner
- add to 
- Fix 
### Deploy to Proxmox --kiosk --k8s-proxmox 
Most places you can deploy using Rancher which is awesome. You can also provision existing or new Kubernetes regardless of what and where.
Up until a while back right around the Broadcom acquisition the Rancher Vsphere provider was our primary deployment type for k8s. Fast forward, it is now Proxmox, thus the reasoning behind creating this now and implementing into this repo. 

I've used k3sup in the past, what a great project, thank you! `https://github.com/alexellis/k3sup`

- Create the bootstrap and workflow using k3sup
- Create the provider engine
- Create the provisioner with our existing proxbox repo logic


```bash
curl -sLS https://get.k3sup.dev | sh
sudo install k3sup /usr/local/bin/
```
```
k3sup --help
```

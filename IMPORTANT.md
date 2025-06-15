## Important
NOT a released version, there are some minor kinks working through. Welcome any feedback or thoughts. 

## Known Issues
Listed by priority

## Things to fix
Listed by priority.
## Things to add

### Deploy to Proxmox --kiosk --k8s-proxmox 
Most places you can deploy using Rancher which is awesome. You can also provision existing or new Kubernetes regardless of what and where.
Up until Broadcom acquisition I lived by the Vsphere k8s integration which is no longer VMware, but now Proxmox, thus the reasoning. 
I've used k3sup in the past, what a great project, thank you! `https://github.com/alexellis/k3sup`

- Create the provider engine
- Create the provisioner with our existing proxbox repo logic


```bash
curl -sLS https://get.k3sup.dev | sh
sudo install k3sup /usr/local/bin/
```
```
k3sup --help
```

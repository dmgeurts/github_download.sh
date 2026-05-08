# github_download.sh

Script for downloading packages from GitHub

Great for scripting through a cronjob and then feeding into a local repo through the built-in feature or having your own process pick up new files.

I use it for feeding packages like sudo (with regex support) and unison (with fsmonitor) into a local Foreman/Katello repo, for distros that don't natively have recent packages available or where the authors don't provide a repo for Katello to mirror.

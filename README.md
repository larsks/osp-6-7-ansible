This repository contains Ansible playbooks for upgrading a RHEL-OSP 6
environment to RHEL-OSP 7.  There are two top-level playbooks
available:

- [all-in-one.yml][1]: This is a simple procedure that shuts down your
  entire OpenStack environment, upgrades packages and database
  schemas, and then restarts everything.

- [service-by-service.yml][2]: This is a substantially more involved
  process that tries to minimize downtime by upgrading one service at
  a time on the controllers, and then upgrading compute nodes
  individually.

[1]: all-in-one-md
[2]: service-by-service.md


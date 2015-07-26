---
title: Upgrading RHEL-OSP 6 to RHEL-OSP 7
---

# Upgrading RHEL-OSP 6 to RHEL-OSP 7

This is an [Ansible][] playbook that will upgrade a RHEL-OSP 6 HA environment to
RHEL-OSP 7.  Your OpenStack environment will be unavailable for the duration
of the upgrade.

[ansible]: http://www.ansible.com/

In order to use this playbook, you must create a "hosts" file
listing your controllers and compute hosts in the following format:

    [controller]
    192.168.100.10
    192.168.100.11
    192.168.100.12

    [compute]
    192.168.100.13

And then run ansible like this:

    ansible-playbook osp-6-7-upgrade.yml

You can run specific sections of the playbook through the use of
Ansible's "tags" feature.  For example, to run just the pre-check
plays:

    ansible-playbook osp-6-7-upgrade.yml -t pre-check

You can also *skip* specific sections of the playbook using the
`--skip-tags` option.  For example, to *skip* the pre-check:

    ansible-playbook osp-6-7-upgrade.yml --skip-tags pre-check

## Make sure cluster state is valid

This play ensures that all your Pacemaker managed resources are active.  If
there are any inactive resources, the playbook will abort.  You can
skip this check by specifying `--skip-tags pre-check` to
`ansible-playbook`.



<!-- break -->

    - hosts: controller[0]
      tags:
        - pre-check
      tasks:
        - name: ensure pacemaker resources are in valid state
          shell: |
            ! pcs status xml | xmllint --xpath '//resource[@active="false"]' - > /dev/null
          changed_when: false
    
## Disable pacemaker managed resources

This play will disable all Pacermaker managed resources and then
wait until all resources have successfully stopped.



<!-- break -->

    - hosts: controller[0]
      tags:
        - disable
        - disable-controller
      tasks:
        - name: disable all resources
          shell: |
            cibadmin -Q |
              xmllint --xpath '/cib/configuration/resources/*/@id' - |
              tr ' ' '\n' |
              cut -f2 -d'"' |
              xargs -n1 pcs resource disable
        - name: wait for all resources to stop
          shell: |
            while pcs status xml |
                xmllint --xpath '//resource[@active="true"]' - > /dev/null; do
              sleep 1
            done
    
## Disable services on compute nodes

Similarly, we stop all OpenStack services on the compute nodes.



<!-- break -->

    - hosts: compute
      tags:
        - disable
        - disable-compute
      tasks:
        - name: "compute: stop openstack services"
          command: openstack-service stop
    
## Upgrade packages

This play performs a `yum ugprade` on all your OpenStack nodes.  We
run `systemctl daemon-reload` after the upgrade to ensure that
systemd will use upgraded unit files.



<!-- break -->

    - hosts: all
      tags:
        - packages
      tasks:
        - name: upgrade all packages
          yum: name=* state=latest
          register: packages
        - name: reload systemd units
          command: systemctl daemon-reload
          when: packages|changed
    
## Bugfixes

These tasks implement workarounds for open bug reports.

Note that many of the package dependency issues will be masked by
the fact that we are performing a `yum upgrade`, rather than
upgrading individual packages (so in this playbook, the dependency
workarounds are basically no-ops).

### BZ 1246542: keystone requires python-oslo-{db,messaging}

The OSP-7 version of Keystone requires the python-oslo-db and
python-oslo-messaging packages, but does not indicate this
requirement as a package dependency.

This task ensures the necessary packages are installed.

- <http://bugzilla.redhat.com/1246542>



<!-- break -->

    - hosts: controller
      tags:
        - keystone
        - bugfix
        - bz1246542
      tasks:
        - name: "BZ 1246542: keystone requires python-oslo-{db,messaging}"
          yum: name={{item}} state=latest
          with_items:
            - python-oslo-messaging
            - python-oslo-db
    
### BZ 1246560: location of token persistence backends has changed

Keystone in Kilo has renamed some Python classes.  In particular,
the token drivers that used to be available in
`keystone.token.backends` are now available in
`keystone.token.persistence.backends`.

This task makes the necessary changes in your keystone.conf.

- <http://bugzilla.redhat.com/1246560>



<!-- break -->

    - hosts: controller
      tags:
        - keystone
        - bugfix
        - bz1246560
      tasks:
        - name: "BZ 1246560: location of token persistence backends has changed"
          command: >
            sed -i '{{item}}' /etc/keystone/keystone.conf
          with_items:
            - 's/keystone.token.backends/keystone.token.persistence.backends/g'
    
### BZ 1246599: neutron requires python-oslo-rootwrap

Neutron in OSP-7 requires the python-oslo-rootwrap package, but does
not specify this requirement as a package dependency.

This task ensures the necessary package is installed.

- <http://bugzilla.redhat.com/1246599>



<!-- break -->

    - hosts: controller
      tags:
        - neutron
        - bugfix
        - bz1246599
      tasks:
        - name: "BZ 1246599: neutron requires python-oslo-rootwrap"
          yum: name={{item}} state=latest
          with_items:
            - python-oslo-rootwrap
    
### BZ 1246638: novncproxy requires upgraded websockify

The novncproxy service in OSP-7 requires at least version 0.6.0 of
the python-websockify package, but does not specify this requirement
as a package dependency.

This task ensures that a functional version of python-websockify is
installed.

- <http://bugzilla.redhat.com/1246638>



<!-- break -->

    - hosts: controller
      tags:
        - nova
        - bugfix
        - bz1246638
      tasks:
        - name: "BZ 1246638: novncproxy requires upgraded websockify"
          yum: name=python-websockify state=latest
    
## Enable galera

This play enables the `galera-master` resource and its requirements
(i.e., `haproxy` and all the vip resources) so that the database
will be accessible where services expect to find it.



<!-- break -->

    - hosts: controller[0]
      tags:
        - pre-database
      tasks:
        - name: start vip resources
          shell: |
            cibadmin -Q |
            xmllint --xpath '//primitive[@type="IPaddr2"]/@id' - |
            tr ' ' '\n' |
            cut -f2 -d'"' |
            xargs -n1 pcs resource enable
        - name: start haproxy resource
          command: pcs resource enable haproxy-clone --wait={{enable_wait}}
        - name: start mariadb galera resource
          command: pcs resource enable galera-master --wait={{enable_wait}}
        - name: ensure mariadb is accepting connections
          shell: |
            timeout 600 sh -c 'until mysql -e "select 1"; do sleep 1; done'
    
## Update OpenStack database schemas

We use the `openstack-db` wrapper script to perform database schema
upgrades on all of our OpenStack services.



<!-- break -->

    - hosts: controller[0]
      tags:
        - database
      tasks:
        - name: update openstack database schemas
          command: openstack-db --service {{item}} --update
          with_items:
            - keystone
            - glance
            - cinder
            - nova
            - neutron
            - heat
    
## Re-enable resources on the controllers

This play will enable all Pacemaker managed resources and wait for
them all to start before continuining.



<!-- break -->

    - hosts: controller[0]
      tags:
        - enable
      tasks:
        - name: enable all resources
          shell: |
            cibadmin -Q |
              xmllint --xpath '/cib/configuration/resources/*/@id' - |
              tr ' ' '\n' |
              cut -f2 -d'"' |
              xargs -n1 pcs resource enable
        - name: wait for all resources to start
          shell: |
            while pcs status xml |
                xmllint --xpath '//resource[@active="false"]' - > /dev/null; do
              sleep 1
            done
    
## Start services on compute nodes

This play will start all OpenStack services on the compute nodes.



<!-- break -->

    - hosts: compute
      tags:
        - enable
      tasks:
        - name: "compute: start openstack services"
          command: openstack-service start
    

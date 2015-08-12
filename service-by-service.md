---
title: Service-by-service upgrade from RHEL-OSP 6 to RHEL-OSP 7
---

# Service-by-service upgrade from RHEL-OSP 6 to RHEL-OSP 7

This collection of playbooks demonstrates a process to upgrade a
RHEL-OSP 6 environment to RHEL-OSP 7 with minimal downtime.  This
playbook includes a suite of other playbooks to upgrade the
individual services.  Individual playbooks include their own
documentation.

**NB**: For this procedure to work, you need RHEL-OSP 6 Neutron
packages that have a fix for [BZ 1250056][].

[bz 1250056]: https://bugzilla.redhat.com/show_bug.cgi?id=1250056



<!-- break -->

    - include: playbooks/wait-all-started.yml
    - include: playbooks/upgrade-galera.yml
    - include: playbooks/upgrade-mongo.yml
    - include: playbooks/upgrade-keystone.yml
    - include: playbooks/upgrade-glance.yml
    - include: playbooks/upgrade-heat.yml
    - include: playbooks/upgrade-cinder.yml
    - include: playbooks/upgrade-ceilometer.yml
    - include: playbooks/upgrade-nova.yml
    - include: playbooks/upgrade-neutron.yml
    - include: playbooks/upgrade-horizon.yml
    - include: playbooks/upgrade-controller-packages.yml
    - include: playbooks/upgrade-compute.yml
    - include: playbooks/upgrade-nova-post.yml
# Wait for Pacemaker resources to start

We want the cluster state to be sane before we start the upgrade
(because if there are resources that are not starting correctly, the
upgrade process will probably hang at some point).  This queries
Pacemaker (using `pcs status xml`) until there are no resources in
the `Stopped` role.



<!-- break -->

    - hosts: controller
      tags:
        - check
      tasks:
        - name: wait for all pacemaker resources to start
          shell: |
            while pcs status xml |
                xmllint --xpath '//resource[@role = "Stopped"]' -; do
              sleep 1
            done
    
# Upgrade MariaDB Galera

This playbook upgrades the MariaDB Galera service.  The play
operates by upgrading each controller in sequence, first stopping
the galera resource through the use of `pcs ban`, then upgrading the
packages, and then allowing Pacemaker to reschedule the resource on
the node.

Because we want to serialize this across the controllers, it is
implemented as a single monolithic play rather than a series of
more granular plays.



<!-- break -->

    - hosts: controller
      serial: 1
      tasks:
        - name: get local pacemaker node name
          command: crm_node -n
          register: crm_node
        - name: stop galera from running on this node
          command: pcs resource ban galera-master {{crm_node.stdout}}
    
        # This waits until there is no longer a "galera" resource running
        # on the local node.
        - name: wait for galera to stop
          shell: |
            while pcs status xml |
                xmllint --xpath '//resource[@id = "galera"]/node[@name="{{crm_node.stdout}}"]' -; do
              sleep 1
            done
    
        - name: upgrade galera packages
          yum: name={{item}} state=latest
          with_items:
            - openstack-selinux
            - "*mariadb*"
            - "*galera*"
        - name: reload systemd
          command: systemctl daemon-reload
        - name: allow galera to run on this node
          command: pcs resource clear galera-master
    
        # This waits for the galera *on this host* to reach the "Master"
        # role.
        - name: wait for galera to start
          shell: |
            while ! pcs status xml |
                xmllint --xpath '//resource[@id = "galera" and @role = "Master"]/node[@name="{{crm_node.stdout}}"]' -; do
              sleep 1
            done
# Upgrade MongoDB

This playbook upgrades the mongodb service.

In order to avoid bringing down all of ceilometer, we first
"unmanage" the resource in order to prevent Pacemaker from responding to
service outages.  Then we are able to use `systemctl` to stop the
`mongod` service on all the controllers.



<!-- break -->

    - hosts: controller
      tags:
        - disable
        - disable-mongo
      tasks:
        - name: unmanage mongod resource
          command: pcs resource unmanage mongod-clone
          run_once: true
        - name: stop mongod resources
          command: systemctl stop mongod
    
With `mongod` stopped, we are able to upgrade the mongodb packages.



<!-- break -->

    - hosts: controller
      tags:
        - packages
      tasks:
        - yum: name={{item}} state=latest
          with_items:
            - openstack-selinux
            - mongodb*
            - python-pymongo*
    
Package updates may include new systemd unit files, so we make sure
that systemd is aware of any updated files.



<!-- break -->

    - include: reload-systemd.yml
    
We restart `mongod` using `systemctl`, make sure it has started
successfully, and then hand control back to Pacemaker.



<!-- break -->

    - hosts: controller
      tags:
        - enable
        - enable-mongo
      tasks:
        - name: start mongo resources
          command: systemctl start mongod
        - name: wait for mongo to start
          shell: >
            while ! crm_resource -r mongod-clone --force-check; do
              sleep 1
            done
        - name: manage mongo resource
          command: pcs resource manage mongod-clone
          run_once: true
# Upgrade Keystone

This playbook ugprades the OpenStack Keystone service.  In order to
avoid bringing down most of the OpenStack environment (due to
Pacemaker resource constraints), we first remove Keystone from
Pacemaker control using the `unmanage` command.  We are then
able to shut down Keystone on the controllers using `systemctl`.



<!-- break -->

    - hosts: controller
      tags:
        - disable
        - disable-keystone
      tasks:
        - name: unmanage keystone resource
          command: pcs resource unmanage keystone-clone
          run_once: true
        - name: stop keystone resources
          command: systemctl stop openstack-keystone
    
Once the service has stopped running, we can upgrade the packages.


<!-- break -->

    - hosts: controller
      tags:
        - packages
      tasks:
        - yum: name={{item}} state=latest
          with_items:
            - openstack-selinux
            - openstack-keystone*
            - python-keystone*
    
## Bug fixes

After upgrading the main Keystone packages, we need to account for a
number of missing package dependencies that are necessary for
Keystone to function properly.

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

This is documented in the [Keystone Upgrade Notes][] of the Kilo
release notes.

[keystone upgrade notes]: https://wiki.openstack.org/wiki/ReleaseNotes/Kilo#Upgrade_Notes_5



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
    
Package updates may include new systemd unit files, so we make sure
that systemd is aware of any updated files.



<!-- break -->

    - include: reload-systemd.yml
    
## Database schema upgrades

We need to update the database schema to the version expected by the
new version of Keystone.



<!-- break -->

    - hosts: controller
      tags:
        - database
      tasks:
        - command: >
            openstack-db --service keystone --update
          run_once: true
    
## Restore service

We start Keystone on each node using `systemctl`, wait for the
service to start successfully, and then finally return control to
Pacemaker.


<!-- break -->

    - hosts: controller
      tags:
        - enable
        - enable-keystone
      tasks:
        - name: start keystone resources
          command: systemctl start openstack-keystone
        - name: wait for keystone to start
          shell: |
            while ! crm_resource -r keystone-clone --force-check; do
              sleep 1
            done
        - name: manage keystone resource
          command: pcs resource manage keystone-clone
          run_once: true
# Upgrade Glance

This playbook ugrades the OpenStack Glance service.  We start by
disabling all Glance services across the cluster.



<!-- break -->

    - hosts: controller
      tags:
        - disable
        - disable-glance
      roles:
        - role: pcs-stop-prefix
          resource_prefix: glance
    
With Glance offline, we are able to upgrade the relevant packages.



<!-- break -->

    - hosts: controller
      tags:
        - packages
      tasks:
        - yum: name={{item}} state=latest
          with_items:
            - openstack-selinux
            - openstack-glance*
            - python-glance*
    
Package updates may include new systemd unit files, so we make sure
that systemd is aware of any updated files.



<!-- break -->

    - include: reload-systemd.yml
    
We need to update the database schema to the version expected by the
updated packages.



<!-- break -->

    - hosts: controller
      tags:
        - database
      tasks:
        - command: >
            openstack-db --service glance --update
          run_once: true
    
Finally, we restart Glance services across the cluster.


<!-- break -->

    - hosts: controller
      tags:
        - enable
        - enable-glance
      roles:
        - role: pcs-start-prefix
          resource_prefix: glance
# Upgrade Heat

This playbook updates OpenStack Heat, using the same process that
we used for Glance.



<!-- break -->

    - hosts: controller
      tags:
        - disable
        - disable-heat
      roles:
        - role: pcs-stop-prefix
          resource_prefix: heat
        - role: pcs-stop
          service: heat
          resources:
            - openstack-heat-engine
    
    - hosts: controller
      tags:
        - packages
      tasks:
        - yum: name={{item}} state=latest
          with_items:
            - openstack-selinux
            - openstack-heat*
            - python-heat*
    
    - include: reload-systemd.yml
    
    - hosts: controller
      tags:
        - database
      tasks:
        - command: >
            openstack-db --service heat --update
          run_once: true
    
    - hosts: controller
      tags:
        - enable
        - enable-heat
      roles:
        - role: pcs-start
          service: heat
          resources:
            - openstack-heat-engine
        - role: pcs-start-prefix
          resource_prefix: heat
# Upgrade Cinder

This playbook updates OpenStack Cinder, using the same process that
we used for Glance.



<!-- break -->

    - hosts: controller
      tags:
        - disable
        - disable-cinder
      roles:
        - role: pcs-stop-prefix
          resource_prefix: cinder
    
    - hosts: controller
      tags:
        - packages
      tasks:
        - yum: name={{item}} state=latest
          with_items:
            - openstack-selinux
            - openstack-cinder*
            - python-cinder*
    
    - include: reload-systemd.yml
    
    - hosts: controller
      tags:
        - database
      tasks:
        - command: >
            openstack-db --service cinder --update
          run_once: true
    
    - hosts: controller
      tags:
        - enable
        - enable-cinder
      roles:
        - role: pcs-start-prefix
          resource_prefix: cinder
# Upgrade Ceilometer

This playbook updates OpenStack Ceilometer, using the same process that
we used for Glance.



<!-- break -->

    - hosts: controller
      tags:
        - disable
        - disable-ceilometer
      roles:
        - role: pcs-stop-prefix
          resource_prefix: openstack-ceilometer
        - role: pcs-stop
          service: ceilometer
          resources:
            - ceilometer-delay-clone
    
    - hosts: controller
      tags:
        - packages
      tasks:
        - name: upgrade ceilometer
          yum: name={{item}} state=latest
          with_items:
            - openstack-selinux
            - openstack-ceilometer*
            - python-ceilometer*
    
    - hosts: controller
      tags:
        - enable
        - enable-ceilometer
      roles:
        - role: pcs-start
          service: ceilometer
          resources: 
            - ceilometer-delay-clone
          wait: false
        - role: pcs-start-prefix
          resource_prefix: openstack-ceilometer
# Upgrade Nova

This playbook updates OpenStack Nova on the controllers.



<!-- break -->

    - hosts: controller
      tags:
        - disable
        - disable-nova
      roles:
        - role: pcs-stop-prefix
          resource_prefix: openstack-nova
    
    - hosts: controller
      tags:
        - packages
      tasks:
        - yum: name={{item}} state=latest
          with_items:
            - openstack-selinux
            - openstack-nova*
            - python-nova*
    
## Bugfixes

### BZ 1250589: openstack-nova requires python-oslo-config

- <http://bugzilla.redhat.com/1250589>


<!-- break -->

    - hosts: controller
      tags:
        - bugfix
        - bz1250589
      tasks:
        - name: "BZ 1250589: openstack-nova requires python-oslo-config"
          yum: name=python-oslo-config state=latest
    
### BZ 1250594: openstack-nova requires python-oslo-utils

- <http://bugzilla.redhat.com/1250594>


<!-- break -->

    - hosts: controller
      tags:
        - bugfix
        - bz1250594
      tasks:
        - name: "BZ 1250594: openstack-nova requires python-oslo-utils"
          yum: name=python-oslo-utils state=latest
    
### BZ 1250597: openstack-nova requires python-oslo-i18n

- <http://bugzilla.redhat.com/1250597>


<!-- break -->

    - hosts: controller
      tags:
        - bugfix
        - bz1250597
      tasks:
        - name: "BZ 1250597: openstack-nova requires python-oslo-i18n"
          yum: name=python-oslo-i18n state=latest
    
### BZ 1250599: openstack-nova requires python-oslo-serialization

- <http://bugzilla.redhat.com/1250599>


<!-- break -->

    - hosts: controller
      tags:
        - bugfix
        - bz1250599
      tasks:
        - name: "BZ 1250599: openstack-nova requires python-oslo-serialization"
          yum: name=python-oslo-serialization state=latest
    
### BZ 1250604: openstack-nova requires python-oslo-messaging

- <http://bugzilla.redhat.com/1250604>


<!-- break -->

    - hosts: controller
      tags:
        - bugfix
        - bz1250604
      tasks:
        - name: "BZ 1250604: openstack-nova requires python-oslo-messaging"
          yum: name=python-oslo-messaging state=latest
    
### BZ 1250606: openstack-nova requires python-oslo-db

- <http://bugzilla.redhat.com/1250606>


<!-- break -->

    - hosts: controller
      tags:
        - bugfix
        - bz1250606
      tasks:
        - name: "BZ 1250606: openstack-nova requires python-oslo-db"
          yum: name=python-oslo-db state=latest
    
### BZ 1250609: openstack-nova requires python-oslo-rootwrap

- <http://bugzilla.redhat.com/1250609>


<!-- break -->

    - hosts: controller
      tags:
        - bugfix
        - bz1250609
      tasks:
        - name: "BZ 1250609: openstack-nova requires python-oslo-rootwrap"
          yum: name=python-oslo-rootwrap state=latest
    
### BZ 1250621: openstack-nova requires upgraded python-neutronclient

- <http://bugzilla.redhat.com/1250621>


<!-- break -->

    - hosts: controller
      tags:
        - bugfix
        - bz1250621
      tasks:
        - name: "BZ 1250621: openstack-nova requires upgraded python-neutronclient"
          yum: name=python-neutronclient state=latest
    
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
        - packages
      tasks:
        - name: "BZ 1246638: novncproxy requires upgraded websockify"
          yum: name=python-websockify state=latest
    
## Reload systemd

Package updates may include new systemd unit files, so we make sure
that systemd is aware of any updated files.



<!-- break -->

    - include: reload-systemd.yml
    
## Database updates

In addition to the schema upgrade, Nova also needs to perform some
data migrations as part of the OSP 6 -> OSP 7 upgrade, as documented
in the [Nova upgrade notes][].

[nova upgrade notes]: https://wiki.openstack.org/wiki/ReleaseNotes/Kilo#Upgrade_Notes_2



<!-- break -->

    - hosts: controller
      tags:
        - database
      tasks:
        - command: >
            openstack-db --service nova --update
          run_once: true
        - name: migrate nova flavor data
          command: >
            runuser -u nova -- nova-manage db
            migrate_flavor_data {{migrate_flavor_max_instance|default('100')}}
          run_once: true
    
## Set API limits

We want to ensure that our OSP-7 controllers are compatible with our
OSP-6 compute nodes.  Once the upgrade of both the controllers and
compute nodes is complete we will remove these API limits.



<!-- break -->

    - hosts: controller
      tags:
        - config
        - config-nova
      tasks:
        - name: set api caps on controller
          command: >
            crudini --set /etc/nova/nova.conf upgrade_levels {{item}} juno
          with_items:
            - compute
    
## Restart Nova services

Lastly we restart Nova services on the controllers.


<!-- break -->

    - hosts: controller
      tags:
        - enable
        - enable-nova
      roles:
        - role: pcs-start-prefix
          resource_prefix: openstack-nova
# Upgrade Neutron

This playbook updates OpenStack Neutron, using the same process that
we used for Glance.



<!-- break -->

    - hosts: controller
      tags:
        - disable
        - disable-neutron
      pre_tasks:
        - name: prevent pacemaker from managing cleanup actions
          command: pcs resource unmanage {{item}}
          with_items:
            - neutron-ovs-cleanup-clone
            - neutron-netns-cleanup-clone
      roles:
        - role: pcs-stop-prefix
          resource_prefix: neutron
          resource_exclude:
            - neutron-ovs-cleanup-clone
            - neutron-netns-cleanup-clone
            - neutron-scale-clone
    
    - hosts: controller
      tags:
        - packages
      tasks:
        - yum: name={{item}} state=latest
          with_items:
            - openstack-selinux
            - openstack-neutron*
            - python-neutron*
            - dnsmasq
            - openvswitch
    
## Bugfixes



<!-- break -->

    - hosts: controller
      tags:
        - bugfix
        - bz1250156
        - bz1250160
        - bz1250164
        - bz1250166
        - bz1250219
        - packages
      tasks:
        - name: "BZ 1250156,1250160,1250164,1250166,1250219: fix neutron dependencies"
          yum: name={{item}} state=latest
          with_items:
            - python-oslo-db
            - python-oslo-messaging
            - python-oslo-i18n
            - python-oslo-config
            - python-oslo-rootwrap
    
## Reload systemd

Package updates may include new systemd unit files, so we make sure
that systemd is aware of any updated files.



<!-- break -->

    - include: reload-systemd.yml
    
## Update database schema



<!-- break -->

    - hosts: controller
      tags:
        - database
      tasks:
        - command: >
            openstack-db --service neutron --update
          run_once: true
    
## Update Neutron rootwrap configuration

According to the [Neutron upgrade notes][], the rootwrap `dhcp.filter`
configuration needs to be edited after upgrading from earlier
releases.

[neutron upgrade notes]: https://wiki.openstack.org/wiki/ReleaseNotes/Kilo#Upgrade_Notes_6


<!-- break -->

    - hosts: controller
      tasks:
        - name: fix neutron dnsmasq rootwrap filter
          command: >
            sed -i '{{item}}' /usr/share/neutron/rootwrap/dhcp.filters
          with_items:
            - '/^dnsmasq:/ s/: .*/: CommandFilter, dnsmasq, root/'
          run_once: true
    
## Restart Neutron services



<!-- break -->

    - hosts: controller
      tags:
        - enable
        - enable-neutron
      roles:
        - role: pcs-start-prefix
          resource_prefix: neutron
          resource_exclude:
            - neutron-ovs-cleanup-clone
            - neutron-netns-cleanup-clone
            - neutron-scale-clone
      tasks:
        - name: allow pacemaker to manage cleanup actions
          command: pcs resource manage {{item}}
          with_items:
            - neutron-ovs-cleanup-clone
            - neutron-netns-cleanup-clone
# Upgrade Horizon

This playbook upgrades OpenStack Horizon.



<!-- break -->

    - hosts: controller
      tags:
        - disable
        - disable-horizon
      roles:
        - role: pcs-stop-prefix
          resource_prefix: horizon
    
    - hosts: controller
      tasks:
        - name: upgrade horizon
          yum: name={{item}} state=latest
          with_items:
            - httpd
            - openstack-dashboard*
            - python-django*
    
## Bugfixes

### BZ 1251322: start-delay on horizon is too short

Restarting httpd would occasionally fail due to delays introduced by
some pre-processing related to Horizon's web interface.

- <https://bugzilla.redhat.com/1251322>



<!-- break -->

    - hosts: controller
      tags:
        - bugfix
        - bz1251322
      tasks:
        - name: update start-delay time on horizon resource
          command: pcs resource op add horizon start interval=0 timeout=120
          run_once: true
    
## Reload systemd


<!-- break -->

    - include: reload-systemd.yml
    
## Restart Apache



<!-- break -->

    - hosts: controller
      tags:
        - enable
        - enable-horizon
      roles:
        - role: pcs-start-prefix
          resource_prefix: horizon
    - hosts: controller
      tasks:
        - name: upgrade all remaining packages
          yum: name=* state=latest
        - name: reload systemd
          command: systemctl daemon-reload
# Upgrade compute nodes

This playbook will upgrade all packages on the compute nodes (and
restart all OpenStack services).  We serialize this so that only one
compute node is upgraded at a time.



<!-- break -->

    - hosts: compute
      serial: 1
      tasks:
        - name: stop openstack services
          command: openstack-service stop
        - name: upgrade all packages
          yum: name=* state=latest
        - name: reload systemd
          command: systemctl daemon-reload
        - name: set api caps
          command: >
            crudini --set /etc/nova/nova.conf upgrade_levels {{item}} juno
          with_items:
            - compute
        - name: start openstack services
          command: openstack-service start
# Remove Nova API caps

Now that we have upgraded all of our controlls and compute nodes, we
can remove the API limits we put in place during the upgrade.

First, we remove the relevant configuration on all of our hosts.



<!-- break -->

    - hosts: all
      tags:
        - post
        - post-nova
      tasks:
        - name: remove api caps
          command: >
            crudini --del /etc/nova/nova.conf upgrade_levels {{item}}
          with_items:
            - compute
    
Then we restart Nova services on the controller...



<!-- break -->

    - hosts: controller
      tags:
        - post
        - post-nova
      roles:
        - role: pcs-stop-prefix
          resource_prefix: openstack-nova
        - role: pcs-start-prefix
          resource_prefix: openstack-nova
    
...followed by Nova services on the compute nodes.



<!-- break -->

    - hosts: compute
      tags:
        - post
        - post-nova
      tasks:
        - name: restart nova services on compute host
          command: openstack-service restart nova

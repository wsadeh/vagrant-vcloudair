require 'securerandom'
require 'etc'
require 'netaddr'

module VagrantPlugins
  module VCloudAir
    module Action
      class BuildVApp
        def initialize(app, env)
          @app = app
          @logger = Log4r::Logger.new('vagrant_vcloudair::action::build_vapp')
        end

        def call(env)
          # FIXME: we need to find a way to clean things up when a SIGINT get
          # called... see env[:interrupted] in the vagrant code

          cfg = env[:machine].provider_config
          cnx = cfg.vcloudair_cnx.driver
          vm_name = env[:machine].name

          if cfg.ip_dns.nil?
            dns_address1 = '8.8.8.8'
            dns_address2 = '8.8.4.4'
          else
            dns_address1 = NetAddr::CIDR.create(cfg.ip_dns.shift).base
            unless cfg.ip_dns.empty?
              dns_address2 = NetAddr::CIDR.create(cfg.ip_dns.shift).base
            end
          end

          if !cfg.ip_subnet.nil?
            @logger.debug("Input address: #{cfg.ip_subnet}")
            cidr = NetAddr::CIDR.create(cfg.ip_subnet)

            range_addresses = cidr.range(0)

            @logger.debug("Range: #{range_addresses}")

            # Delete the "network" address from the range.
            range_addresses.shift
            # Retrieve the first usable IP, to be used as a gateway.
            gateway_ip = range_addresses.shift
            # Reverse the array in place.
            range_addresses.reverse!
            # Delete the "broadcast" address from the range.
            range_addresses.shift
            # Reverse back the array.
            range_addresses.reverse!

            @logger.debug("Gateway IP: #{gateway_ip.to_s}")
            @logger.debug("Netmask: #{cidr.wildcard_mask}")
            @logger.debug(
              "IP Pool: #{range_addresses.first}-#{range_addresses.last}"
            )
            @logger.debug("DNS1: #{dns_address1} DNS2: #{dns_address2}")

            network_options = {
              :name               => 'Vagrant-vApp-Net',
              :gateway            => gateway_ip.to_s,
              :netmask            => cidr.wildcard_mask,
              :start_address      => range_addresses.first,
              :end_address        => range_addresses.last,
              :fence_mode         => 'natRouted',
              :ip_allocation_mode => 'POOL',
              :parent_network     => cfg.vdc_network_id,
              :enable_firewall    => 'false',
              :dns1               => dns_address1,
              :dns2               => dns_address2
            }

          elsif !cfg.network_bridge.nil?
            # Bridged mode, avoid deploying a vShield Edge altogether.
            network_options = {
              :name               => 'Vagrant-vApp-Net',
              :fence_mode         => 'bridged',
              :ip_allocation_mode => 'POOL',
              :parent_network     => cfg.vdc_network_id
            }

            env[:bridged_network] = true

          else

            @logger.debug("DNS1: #{dns_address1} DNS2: #{dns_address2}")
            # No IP subnet specified, reverting to defaults
            network_options = {
              :name               => 'Vagrant-vApp-Net',
              :gateway            => '10.1.1.1',
              :netmask            => '255.255.255.0',
              :start_address      => '10.1.1.2',
              :end_address        => '10.1.1.254',
              :fence_mode         => 'natRouted',
              :ip_allocation_mode => 'POOL',
              :parent_network     => cfg.vdc_network_id,
              :enable_firewall    => 'false',
              :dns1               => dns_address1,
              :dns2               => dns_address2
            }

          end

          if env[:machine].get_vapp_id.nil?
            env[:ui].info(I18n.t('vagrant_vcloudair.vapp.build_vapp'))

            vapp_prefix = cfg.vapp_prefix
            vapp_prefix = 'Vagrant' if vapp_prefix.nil?

            compose = cnx.compose_vapp_from_vm(
              cfg.vdc_id,
              "#{vapp_prefix}-#{Etc.getlogin}-#{Socket.gethostname.downcase}-" +
              "#{SecureRandom.hex(4)}",
              "vApp created by #{Etc.getlogin} running on " +
              "#{Socket.gethostname.downcase} using vagrant-vcloudair on " +
              "#{Time.now.strftime("%B %d, %Y")}",
              {
                vm_name => cfg.catalog_item[:vms_hash].first.last[:id]
              },
              network_options
            )
            @logger.debug('Launch Compose vApp...')

            # Fetch thenewly created vApp ID
            vapp_id = compose[:vapp_id]

            # putting the vApp Id in a globally reachable var and file.
            env[:machine].vappid = vapp_id

            # Wait for the task to finish.
            wait = cnx.wait_task_completion(compose[:task_id])

            unless wait[:errormsg].nil?
              fail Errors::ComposeVAppError, :message => wait[:errormsg]
            end

            # Fetching new vApp object to check stuff.
            new_vapp = cnx.get_vapp(vapp_id)

            if new_vapp
              env[:ui].success(I18n.t('vagrant_vcloudair.vapp.vapp_created',
                                      vapp_name: new_vapp[:name]))

              # Add the vm id as machine.id
              new_vm_properties = new_vapp[:vms_hash].fetch(vm_name)
              env[:machine].id = new_vm_properties[:id]

              ### SET GUEST CONFIG
              @logger.info(
                "Setting Guest Customization on ID: [#{vm_name}] " +
                "of vApp [#{new_vapp[:name]}]"
              )

              set_custom = cnx.set_vm_guest_customization(
                new_vm_properties[:id],
                vm_name,
                {
                  :enabled              => true,
                  :admin_passwd_enabled => false
                }
              )
              wait = cnx.wait_task_completion(set_custom)

              unless wait[:errormsg].nil?
                fail Errors::ComposeVAppError, :message => wait[:errormsg]
              end

            else
              env[:ui].error(I18n.t(
                             'vagrant_vcloudair.vapp.vapp_creation_failed'),
                             vapp_name: new_vapp[:name])
              fail Errors::ComposeVAppError,
                   :message => 'vApp created but cannot get a working id, \
                                please report this error'
            end

          else
            env[:ui].info(I18n.t('vagrant_vcloudair.vapp.adding_vm'))

            recompose = cnx.recompose_vapp_from_vm(
              env[:machine].get_vapp_id,
              {
                vm_name => cfg.catalog_item[:vms_hash].first.last[:id]
              },
              network_options
            )

            @logger.info('Waiting for the recompose task to complete ...')

            # Wait for the task to finish.
            wait = cnx.wait_task_completion(recompose[:task_id])

            unless wait[:errormsg].nil?
              fail Errors::ComposeVAppError, :message => wait[:errormsg]
            end

            new_vapp = cnx.get_vapp(env[:machine].get_vapp_id)

            if new_vapp
              new_vm_properties = new_vapp[:vms_hash].fetch(vm_name)
              env[:machine].id = new_vm_properties[:id]

              ### SET GUEST CONFIG
              @logger.info(
                'Setting Guest Customization on ID: ' +
                "[#{new_vm_properties[:id]}] of vApp [#{new_vapp[:name]}]"
              )

              set_custom = cnx.set_vm_guest_customization(
                new_vm_properties[:id],
                vm_name,
                {
                  :enabled              => true,
                  :admin_passwd_enabled => false
                }
              )
              wait = cnx.wait_task_completion(set_custom)

              unless wait[:errormsg].nil?
                fail Errors::ComposeVAppError, :message => wait[:errormsg]
              end

            else
              # env[:ui].error("VM #{vm_name} add to #{new_vapp[:name]} failed!")
              env[:ui].error(I18n.t('vagrant_vcloudair.vapp.vm_add_failed',
                                    vm_name: vm_name,
                                    vapp_name: new_vapp[:name]))
              fail Errors::ComposeVAppError,
                   :message => 'VM added to vApp but cannot get a working id, \
                                please report this error'
            end
          end

          @app.call env
        end
      end
    end
  end
end

#
# Copyright 2010 Red Hat, Inc.
#
# This is free software; you can redistribute it and/or modify it
# under the terms of the GNU Lesser General Public License as
# published by the Free Software Foundation; either version 3 of
# the License, or (at your option) any later version.
#
# This software is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this software; if not, write to the Free
# Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA
# 02110-1301 USA, or see the FSF site: http://www.fsf.org.

require 'rubygems'
require 'boxgrinder-build/plugins/base-plugin'
require 'AWS'
require 'open-uri'

module BoxGrinder
  class EBSPlugin < BasePlugin
    KERNELS = {
        'eu-west-1' => {
            'i386' => {:aki => 'aki-4deec439'},
            'x86_64' => {:aki => 'aki-4feec43b'}
        },
        'ap-southeast-1' => {
            'i386' => {:aki => 'aki-13d5aa41'},
            'x86_64' => {:aki => 'aki-11d5aa43'}
        },
        'us-west-1' => {
            'i386' => {:aki => 'aki-99a0f1dc'},
            'x86_64' => {:aki => 'aki-9ba0f1de'}
        },
        'us-east-1' => {
            'i386' => {:aki => 'aki-407d9529'},
            'x86_64' => {:aki => 'aki-427d952b'}
        }
    }

    def after_init
      if valid_platform?
        @current_avaibility_zone = open('http://169.254.169.254/latest/meta-data/placement/availability-zone').string
        @region = @current_avaibility_zone.scan(/((\w+)-(\w+)-(\d+))/).flatten.first
      end

      set_default_config_value('availability_zone', @current_avaibility_zone)
      set_default_config_value('delete_on_termination', true)

      register_supported_os('fedora', ['13', '14', '15'])
      register_supported_os('rhel', ['6'])
    end

    def execute(type = :ebs)
      validate_plugin_config(['access_key', 'secret_access_key', 'account_number'], 'http://boxgrinder.org/tutorials/boxgrinder-build-plugins/#EBS_Delivery_Plugin')

      raise "You try to run this plugin on invalid platform. You can run EBS delivery plugin only on EC2." unless valid_platform?
      raise "You can only convert to EBS type AMI appliances converted to EC2 format. Use '-p ec2' switch. For more info about EC2 plugin see http://boxgrinder.org/tutorials/boxgrinder-build-plugins/#EC2_Platform_Plugin." unless @previous_plugin_info[:name] == :ec2
      raise "You selected #{@plugin_config['availability_zone']} avaibility zone, but your instance is running in #{@current_avaibility_zone} zone. Please change avaibility zone in plugin configuration file to #{@current_avaibility_zone} (see http://boxgrinder.org/tutorials/boxgrinder-build-plugins/#EBS_Delivery_Plugin) or use another instance in #{@plugin_config['availability_zone']} zone to create your EBS AMI." if @plugin_config['availability_zone'] != @current_avaibility_zone

      ebs_appliance_description = "#{@appliance_config.summary} | Appliance version #{@appliance_config.version}.#{@appliance_config.release} | #{@appliance_config.hardware.arch} architecture"

      @ec2 = AWS::EC2::Base.new(:access_key_id => @plugin_config['access_key'], :secret_access_key => @plugin_config['secret_access_key'])

      @log.debug "Checking if appliance is already registered..."

      ami_id = already_registered?(ebs_appliance_name)

      if ami_id
        @log.warn "EBS AMI '#{ebs_appliance_name}' is already registered as '#{ami_id}' (region: #{@region})."
        return
      end

      @log.info "Creating new EBS volume..."

      size = 0

      @appliance_config.hardware.partitions.each_value { |partition| size += partition['size'] }

      # create_volume with 10GB size
      volume_id = @ec2.create_volume(:size => size.to_s, :availability_zone => @plugin_config['availability_zone'])['volumeId']

      @log.debug "Volume #{volume_id} created."
      @log.debug "Waiting for EBS volume #{volume_id} to be available..."

      # wait fo volume to be created
      wait_for_volume_status('available', volume_id)

      # get first free device to mount the volume
      suffix = free_device_suffix

      @log.trace "Got free device suffix: '#{suffix}'"
      @log.trace "Reading current instance id..."

      # read current instance id
      instance_id = open('http://169.254.169.254/latest/meta-data/instance-id').string

      @log.trace "Got: #{instance_id}"
      @log.info "Attaching created volume..."

      # attach the volume to current host
      @ec2.attach_volume(:device => "/dev/sd#{suffix}", :volume_id => volume_id, :instance_id => instance_id)

      @log.debug "Waiting for EBS volume to be attached..."

      # wait for volume to be attached
      wait_for_volume_status('in-use', volume_id)

      sleep 10 # let's wait to discover the attached volume by OS

      @log.info "Copying data to EBS volume..."

      @image_helper.customize([@previous_deliverables.disk, device_for_suffix(suffix)], :automount => false) do |guestfs, guestfs_helper|
        sync_filesystem(guestfs, guestfs_helper)

        # Remount the EBS volume
        guestfs_helper.mount_partition(guestfs.list_devices.last, '/')

        @log.debug "Adjusting /etc/fstab..."
        adjust_fstab(guestfs)
      end

      @log.debug "Detaching EBS volume..."

      @ec2.detach_volume(:device => "/dev/sd#{suffix}", :volume_id => volume_id, :instance_id => instance_id)

      @log.debug "Waiting for EBS volume to be available..."

      wait_for_volume_status('available', volume_id)

      @log.info "Creating snapshot from EBS volume..."

      snapshot_id = @ec2.create_snapshot(
          :volume_id => volume_id,
          :description => ebs_appliance_description)['snapshotId']

      @log.debug "Waiting for snapshot #{snapshot_id} to be completed..."

      wait_for_snapshot_status('completed', snapshot_id)

      @log.debug "Deleting temporary EBS volume..."

      @ec2.delete_volume(:volume_id => volume_id)

      @log.info "Registering image..."

      image_id = @ec2.register_image(
          :block_device_mapping => [{
                                        :device_name => '/dev/sda1',
                                        :ebs_snapshot_id => snapshot_id,
                                        :ebs_delete_on_termination => @plugin_config['delete_on_termination']
                                    },
                                    {
                                        :device_name => '/dev/sdb',
                                        :virtual_name => 'ephemeral0'
                                    },
                                    {
                                        :device_name => '/dev/sdc',
                                        :virtual_name => 'ephemeral1'
                                    },
                                    {
                                        :device_name => '/dev/sdd',
                                        :virtual_name => 'ephemeral2'
                                    },
                                    {
                                        :device_name => '/dev/sde',
                                        :virtual_name => 'ephemeral3'
                                    }],
          :root_device_name => '/dev/sda1',
          :architecture => @appliance_config.hardware.base_arch,
          :kernel_id => KERNELS[@region][@appliance_config.hardware.base_arch][:aki],
          :name => ebs_appliance_name,
          :description => ebs_appliance_description)['imageId']

      @log.info "EBS AMI '#{ebs_appliance_name}' registered: #{image_id} (region: #{@region})"
    end

    def sync_filesystem(guestfs, guestfs_helper)
      @log.info "Synchronizing filesystems..."

      # Create mount point in libguestfs
      guestfs.mkmountpoint('/in')
      guestfs.mkmountpoint('/out')
      guestfs.mkmountpoint('/out/in')

      # Create filesystem on EC2 disk
      guestfs.mkfs(@appliance_config.hardware.partitions['/']['type'], guestfs.list_devices.last)
      # Set EC root partition label
      guestfs.set_e2label(guestfs.list_devices.last, '79d3d2d4') # This is a CRC32 from /

      # Mount EBS volume to /out
      guestfs_helper.mount_partition(guestfs.list_devices.last, '/out/in')

      # Mount EC2 partition to /in mount point
      guestfs_helper.mount_partition(guestfs.list_devices.first, '/in')

      @log.debug "Copying files..."

      # Copy the filesystem
      guestfs.cp_a('/in/', '/out')

      @log.debug "Files copied."

      # Better make sure...
      guestfs.sync

      guestfs.umount('/out/in')
      guestfs.umount('/in')

      guestfs.rmmountpoint('/out/in')
      guestfs.rmmountpoint('/out')
      guestfs.rmmountpoint('/in')

      @log.info "Filesystems synchronized."
    end

    def ebs_appliance_name
      base_path = "#{@appliance_config.name}/#{@appliance_config.os.name}/#{@appliance_config.os.version}/#{@appliance_config.version}.#{@appliance_config.release}"

      return "#{base_path}/#{@appliance_config.hardware.arch}" unless @plugin_config['snapshot']

      snapshot = 1

      while already_registered?("#{base_path}-SNAPSHOT-#{snapshot}/#{@appliance_config.hardware.arch}")
        snapshot += 1
      end

      "#{base_path}-SNAPSHOT-#{snapshot}/#{@appliance_config.hardware.arch}"
    end

    def already_registered?(name)
      images = @ec2.describe_images(:owner_id => @plugin_config['account_number'].to_s.gsub(/-/, ''))

      return false if images.nil? or images['imagesSet'].nil?

      images['imagesSet']['item'].each { |image| return image['imageId'] if image['name'] == name }

      false
    end

    def adjust_fstab(guestfs)
      guestfs.sh("cat /etc/fstab | grep -v '/mnt' | grep -v '/data' | grep -v 'swap' > /etc/fstab.new")
      guestfs.mv("/etc/fstab.new", "/etc/fstab")
    end

    def wait_for_snapshot_status(status, snapshot_id)
      snapshot = @ec2.describe_snapshots(:snapshot_id => snapshot_id)['snapshotSet']['item'].first

      unless snapshot['status'] == status
        sleep 2
        wait_for_snapshot_status(status, snapshot_id)
      end
    end

    def wait_for_volume_status(status, volume_id)
      volume = @ec2.describe_volumes(:volume_id => volume_id)['volumeSet']['item'].first

      unless volume['status'] == status
        sleep 2
        wait_for_volume_status(status, volume_id)
      end
    end

    def device_for_suffix(suffix)
      return "/dev/sd#{suffix}" if File.exists?("/dev/sd#{suffix}")
      return "/dev/xvd#{suffix}" if File.exists?("/dev/xvd#{suffix}")

      raise "Device for suffix '#{suffix}' not found!"
    end

    def free_device_suffix
      ("f".."p").each do |suffix|
        return suffix unless File.exists?("/dev/sd#{suffix}") or File.exists?("/dev/xvd#{suffix}")
      end

      raise "Found too many attached devices. Cannot attach EBS volume."
    end

    def valid_platform?
      begin
        return Resolv.getname("169.254.169.254").include?(".ec2.internal")
      rescue Resolv::ResolvError
        false
      end
    end
  end
end

plugin :class => BoxGrinder::EBSPlugin, :type => :delivery, :name => :ebs, :full_name => "Elastic Block Storage"

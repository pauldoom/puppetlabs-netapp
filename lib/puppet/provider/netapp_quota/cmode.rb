require 'puppet/provider/netapp'
Puppet::Type.type(:netapp_quota).provide(:cmode, :parent => Puppet::Provider::Netapp) do

  confine :feature => :posix
  defaultfor :feature => :posix
  
  # Restrict to CMode
  confine :true => begin
    a = Puppet::Node::Facts.indirection
    a.terminus_class = :network_device
    a.find(Puppet::Indirector::Request.new(:facts, :find, "clustered", nil))
  rescue
    :false
  end
  
  netapp_commands :list => {:api => 'quota-list-entries-iter', :iter => :true, :result_element => 'attributes-list'}
  netapp_commands :add => 'quota-add-entry'
  netapp_commands :del => 'quota-delete-entry'
  netapp_commands :mod => 'quota-modify-entry'
  netapp_commands :resize => 'quota-resize'
  netapp_commands :qoff => 'quota-off'
  netapp_commands :qon => 'quota-on'
  netapp_commands :status => 'quota-status'

  def self.instances
    instances = []

    # in theory we could run quota-list-entries to get all quota
    # targets and then run quota-get-entry against each target to
    # get the thresholds. Unfortunately the NetApp SDK opens a new
    # HTTPS connection for each request so this does not scale well.
    # As a workaround pass include-output-entry and parse the
    # thresholds by hand.
    response = list('include-output-entry', 'true')
    response.each do |quota_entry|
      quota_hash = {
        :name   => quota_entry.child_get_string("quota-target"),
        :type   => quota_entry.child_get_string("quota-type").intern,
        :ensure => :present
      }

      if volume = quota_entry.child_get_string("volume") and !volume.empty?
        quota_hash[:volume] = volume
      end

      if qtree = quota_entry.child_get_string("qtree") and !qtree.empty?
        quota_hash[:qtree] = qtree
      end

      # according to na_quota(5) entries can span over multiple lines
      quota_hash[:disklimit] = size_in_byte(quota_entry.child_get_string('disk-limit')) unless quota_entry.child_get_string('disk-limit').nil? or quota_entry.child_get_string('disk-limit') == '-'
      quota_hash[:filelimit] = size_in_byte(quota_entry.child_get_string('size-limit')) unless quota_entry.child_get_string('size-limit').nil? or quota_entry.child_get_string('size-limit') == '-'
      quota_hash[:threshold] = size_in_byte(quota_entry.child_get_string('threshold')) unless quota_entry.child_get_string('threshold').nil? or quota_entry.child_get_string('threshold') == '-'
      quota_hash[:softdisklimit] = size_in_byte(quota_entry.child_get_string('soft-disk-limit')) unless quota_entry.child_get_string('soft-disk-limit').nil? or quota_entry.child_get_string('soft-disk-limit') == '-'
      quota_hash[:softfilelimit] = size_in_byte(quota_entry.child_get_string('soft-size-limit')) unless quota_entry.child_get_string('soft-size-limit').nil? or quota_entry.child_get_string('soft-size-limit') == '-'

      instances << new(quota_hash)
    end
    instances
  end

  def self.prefetch(resources)
    instances.each do |prov|
      if resource = resources[prov.name]
        resource.provider = prov
      end
    end
  end

  def exists?
    get(:ensure) != :absent
  end

  # converts a string that represents a size (like "1K", "20M", etc) into an
  # integer
  def self.size_in_byte(input, default_unit = nil)
    base = { 'K' => 10, 'M' => 20, 'G' => 30, 'T' => 40 }
    if match = /^([0-9]+)([KMGT])?$/.match(input.to_s)
      number = match.captures[0].to_i
      if unit = (match.captures[1] || default_unit)
        number <<= base[unit]
      end
      number
    else
      raise ArgumentError, "Invalid input #{input.inspect}"
    end
  end

  # Converts a limit value (which is either a number or the symbol :absent)
  # to a value that is accepted by the NetApp API calls. A few api calls
  # expect the values to be in KiB. In this case you can specify a unit you
  # want the limit value to be converted into
  def limit_to_api(value, unit =  nil)
    base = { 'K' => 10, 'M' => 20, 'G' => 30, 'T' => 40 }
    if value == :absent
      '-'
    else
      if unit and base.include? unit
        (value >> base[unit]).to_s
      else
        value.to_s
      end
    end
  end

  def create
    args = [ 'quota-target', resource[:name] ]
    args << 'quota-type' << resource[:type].to_s
    args << 'volume' <<  resource[:volume] if resource[:volume]
    if resource[:qtree].nil? or resource[:type] == :tree
      args << 'qtree' << ''
    else
      args << 'qtree' << resource[:qtree]
    end

    # The API expects the disklimit and threshold to be specified in KiB. The
    # file limit is expected to be an absolute number. All limits accept '-'
    # as a value for unlimited / no limit which is expressed in the puppet world
    # as absent
    args << 'disk-limit' << limit_to_api(resource[:disklimit], 'K') if resource[:disklimit]
    args << 'soft-disk-limit' << limit_to_api(resource[:softdisklimit], 'K') if resource[:softdisklimit]
    args << 'file-limit' << limit_to_api(resource[:filelimit]) if resource[:filelimit]
    args << 'soft-file-limit' << limit_to_api(resource[:softfilelimit]) if resource[:softfilelimit]
    args << 'threshold' << limit_to_api(resource[:threshold], 'K') if resource[:threshold]
    add(*args)
    @need_restart = true
  end

  def default_api_args
    ["quota-target", resource[:name], "quota-type", @property_hash[:type].to_s, "volume", @property_hash[:volume] || "", "qtree", @property_hash[:qtree] || ""]
  end

  def destroy
    del(*default_api_args)
  end

  # Define getter methods
  resource_type.validproperties.each do |prop|
    define_method(prop) do
      @property_hash[prop] || :absent
    end
  end

  # Define setter methods
  def qtree=(new_value)
    raise Puppet::Error, "Changing the qtree of an already existing quota is not implemented. Please perform the necessary steps manually"
  end

  def type=(new_value)
    raise Puppet::Error, "Changing the type of an already existing quota is not implemented. Please perform the necessary steps manually"
  end

  def volume=(new_value)
    raise Puppet::Error, "Changing the volume of an already existing quota is not implemented. Please perform the necessary steps manually"
  end

  def disklimit=(new_value)
    args = default_api_args << 'disk-limit' << limit_to_api(new_value, 'K')
    mod(*args)
  end

  def softdisklimit=(new_value)
    args = default_api_args << 'soft-disk-limit' << limit_to_api(new_value, 'K')
    mod(*args)
  end

  def threshold=(new_value)
    args = default_api_args << 'threshold' << limit_to_api(new_value, 'K')
    mod(*args)
  end

  def filelimit=(new_value)
    args = default_api_args << 'file-limit' << limit_to_api(new_value)
    mod(*args)
  end

  def softfilelimit=(new_value)
    args = default_api_args << 'soft-file-limit' << limit_to_api(new_value)
    mod(*args)
  end

  # if we modify a quota it does not take effect immediatly: To actually change
  # the quota we either have to run quota-resize (which does only work if the
  # quota was already present) or deactivate and reactivate the quota if the
  # quota was absent before
  def flush
    # if we know the volume of the current instance, we'll extract it from
    # the property_hash. If the property_hash is absent (e.g. the volume has
    # just been created and was not prefetched) use the should-value
    volume = @property_hash[:volume] || resource[:volume]

    # check the current state so we do not activate quotas on a
    # volume that has quotas turned off.
    if status('volume', volume).child_get_string('status') == 'on'
      if @need_restart
        qoff 'volume', volume
        qon 'volume', volume
        @need_restart = false
      else
        resize 'volume', volume
      end
    end
  end
end

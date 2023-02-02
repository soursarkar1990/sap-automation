#########################################################################################
#                                                                                       #
#  Primary Network Interface                                                            #
#                                                                                       #
#########################################################################################
resource "azurerm_network_interface" "ASCS" {
  provider = azurerm.main
  count    = local.enable_deployment ? local.ASCS_server_count : 0
  name = format("%s%s%s%s%s",
    var.naming.resource_prefixes.nic,
    local.prefix,
    var.naming.separator,
    var.naming.virtualmachine_names.ASCS_VMNAME[count.index],
    local.resource_suffixes.nic
  )
  location                      = var.resource_group[0].location
  resource_group_name           = var.resource_group[0].name
  enable_accelerated_networking = local.ASCS_sizing.compute.accelerated_networking

  dynamic "ip_configuration" {
    iterator = pub
    for_each = local.ASCS_ips
    content {
      name      = pub.value.name
      subnet_id = pub.value.subnet_id
      private_ip_address = try(pub.value.nic_ips[count.index],
        var.application_tier.use_DHCP ? (
          null) : (
          cidrhost(local.application_subnet_exists ?
            data.azurerm_subnet.subnet_sap_app[0].address_prefixes[0] :
            azurerm_subnet.subnet_sap_app[0].address_prefixes[0],
            tonumber(count.index) + local.ip_offsets.ASCS_vm + pub.value.offset
          )
        )
      )
      private_ip_address_allocation = length(try(pub.value.nic_ips[count.index], "")) > 0 ? (
        "Static") : (
        pub.value.private_ip_address_allocation
      )

      primary = pub.value.primary
    }
  }

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azurerm_network_interface_application_security_group_association" "ASCS" {
  provider = azurerm.main
  count = local.enable_deployment ? (
    var.deploy_application_security_groups ? local.ASCS_server_count : 0) : (
    0
  )

  network_interface_id          = azurerm_network_interface.ASCS[count.index].id
  application_security_group_id = azurerm_application_security_group.app[0].id
}


#########################################################################################
#                                                                                       #
#  Admin Network Interface                                                              #
#                                                                                       #
#########################################################################################

resource "azurerm_network_interface" "ASCS_admin" {
  provider = azurerm.main
  count = local.enable_deployment && var.application_tier.dual_nics && length(try(var.admin_subnet.id, "")) > 0 ? (
    local.ASCS_server_count) : (
    0
  )
  name = format("%s%s%s%s%s",
    var.naming.resource_prefixes.admin_nic,
    local.prefix,
    var.naming.separator,
    var.naming.virtualmachine_names.ASCS_VMNAME[count.index],
    local.resource_suffixes.admin_nic
  )
  location                      = var.resource_group[0].location
  resource_group_name           = var.resource_group[0].name
  enable_accelerated_networking = local.ASCS_sizing.compute.accelerated_networking

  ip_configuration {
    name      = "IPConfig1"
    subnet_id = var.admin_subnet.id
    private_ip_address = try(local.ASCS_admin_nic_ips[count.index], var.application_tier.use_DHCP ? (
      null) : (
      cidrhost(
        var.admin_subnet.address_prefixes[0],
        tonumber(count.index) + local.admin_ip_offsets.ASCS_vm
      )
      )
    )
    private_ip_address_allocation = length(try(local.ASCS_admin_nic_ips[count.index], "")) > 0 ? (
      "Static") : (
      "Dynamic"
    )
  }
}

# Associate ASCS VM NICs with the Load Balancer Backend Address Pool
resource "azurerm_network_interface_backend_address_pool_association" "ASCS" {
  provider                = azurerm.main
  count                   = local.enable_ASCS_lb_deployment ? local.ASCS_server_count : 0
  network_interface_id    = azurerm_network_interface.ASCS[count.index].id
  ip_configuration_name   = azurerm_network_interface.ASCS[count.index].ip_configuration[0].name
  backend_address_pool_id = azurerm_lb_backend_address_pool.ASCS[0].id
}

# Create the ASCS Linux VM(s)
resource "azurerm_linux_virtual_machine" "ASCS" {
  provider = azurerm.main
  count = local.enable_deployment && upper(var.application_tier.ASCS_os.os_type) == "LINUX" ? (
    local.ASCS_server_count) : (
    0
  )
  name = format("%s%s%s%s%s",
    var.naming.resource_prefixes.vm,
    local.prefix,
    var.naming.separator,
    var.naming.virtualmachine_names.ASCS_VMNAME[count.index],
    local.resource_suffixes.vm
  )
  computer_name       = var.naming.virtualmachine_names.ASCS_COMPUTERNAME[count.index]
  location            = var.resource_group[0].location
  resource_group_name = var.resource_group[0].name

  //If no ppg defined do not put the ASCS servers in a proximity placement group
  proximity_placement_group_id = local.ASCS_no_ppg ? (
    null) : (
    local.ASCS_zonal_deployment ? var.ppg[count.index % max(local.ASCS_zone_count, 1)].id : var.ppg[0].id
  )

  //If more than one servers are deployed into a single zone put them in an availability set and not a zone
  availability_set_id = local.use_ASCS_avset ? (
    azurerm_availability_set.ASCS[count.index % max(local.ASCS_zone_count, 1)].id) : (
    null
  )

  //If length of zones > 1 distribute servers evenly across zones
  zone = local.use_ASCS_avset ? null : try(local.ASCS_zones[count.index % max(local.ASCS_zone_count, 1)], null)
  network_interface_ids = var.application_tier.dual_nics ? (
    var.options.legacy_nic_order ? (
      [
        azurerm_network_interface.ASCS_admin[count.index].id,
        azurerm_network_interface.ASCS[count.index].id
      ]) : (
      [
        azurerm_network_interface.ASCS[count.index].id,
        azurerm_network_interface.ASCS_admin[count.index].id
      ]
    )
    ) : (
    [azurerm_network_interface.ASCS[count.index].id]
  )

  size                            = length(local.ASCS_size) > 0 ? local.ASCS_size : local.ASCS_sizing.compute.vm_size
  admin_username                  = var.sid_username
  admin_password                  = local.enable_auth_key ? null : var.sid_password
  disable_password_authentication = !local.enable_auth_password

  dynamic "admin_ssh_key" {
    for_each = range(var.deployment == "new" ? 1 : (local.enable_auth_password ? 0 : 1))
    content {
      username   = var.sid_username
      public_key = var.sdu_public_key
    }
  }

  custom_data = var.deployment == "new" ? var.cloudinit_growpart_config : null

  dynamic "os_disk" {
    iterator = disk
    for_each = flatten(
      [
        for storage_type in local.ASCS_sizing.storage : [
          for disk_count in range(storage_type.count) :
          {
            name      = storage_type.name,
            id        = disk_count,
            disk_type = storage_type.disk_type,
            size_gb   = storage_type.size_gb,
            caching   = storage_type.caching
          }
        ]
        if storage_type.name == "os"
      ]
    )

    content {
      name = format("%s%s%s%s%s",
        var.naming.resource_prefixes.osdisk,
        local.prefix,
        var.naming.separator,
        var.naming.virtualmachine_names.ASCS_VMNAME[count.index],
        local.resource_suffixes.osdisk
      )
      caching                = disk.value.caching
      storage_account_type   = disk.value.disk_type
      disk_size_gb           = disk.value.size_gb
      disk_encryption_set_id = try(var.options.disk_encryption_set_id, null)
    }
  }

  source_image_id = var.application_tier.ASCS_os.type == "custom" ? var.application_tier.ASCS_os.source_image_id : null

  dynamic "source_image_reference" {
    for_each = range(var.application_tier.ASCS_os.type == "marketplace" ? 1 : 0)
    content {
      publisher = var.application_tier.ASCS_os.publisher
      offer     = var.application_tier.ASCS_os.offer
      sku       = var.application_tier.ASCS_os.sku
      version   = var.application_tier.ASCS_os.version
    }
  }

  dynamic "plan" {
    for_each = range(var.application_tier.ASCS_os.type == "marketplace_with_plan" ? 1 : 0)
    content {
      name      = var.application_tier.ASCS_os.offer
      publisher = var.application_tier.ASCS_os.publisher
      product   = var.application_tier.ASCS_os.sku
    }
  }
  boot_diagnostics {
    storage_account_uri = var.storage_bootdiag_endpoint
  }

  license_type = length(var.license_type) > 0 ? var.license_type : null

  tags = try(var.application_tier.ASCS_tags, {})

  dynamic "identity" {
    for_each = range(var.use_msi_for_clusters && var.application_tier.ASCS_high_availability ? 1 : 0)
    content {
      type = "SystemAssigned"
    }
  }

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azurerm_role_assignment" "ASCS" {
  provider = azurerm.main
  count = (
    var.use_msi_for_clusters &&
    local.enable_deployment &&
    upper(var.application_tier.ASCS_os.os_type) == "LINUX" &&
    length(var.fencing_role_name) > 0 &&
    local.ASCS_server_count > 1
    ) ? (
    local.ASCS_server_count
    ) : (
    0
  )

  scope                = var.resource_group[0].id
  role_definition_name = var.fencing_role_name
  principal_id         = azurerm_linux_virtual_machine.ASCS[count.index].identity[0].principal_id

}
# Create the ASCS Windows VM(s)
resource "azurerm_windows_virtual_machine" "ASCS" {
  provider = azurerm.main
  count = local.enable_deployment && upper(var.application_tier.ASCS_os.os_type) == "WINDOWS" ? (
    local.ASCS_server_count) : (
    0
  )
  name = format("%s%s%s%s%s",
    var.naming.resource_prefixes.vm,
    local.prefix,
    var.naming.separator,
    var.naming.virtualmachine_names.ASCS_VMNAME[count.index],
    local.resource_suffixes.vm
  )
  computer_name       = var.naming.virtualmachine_names.ASCS_COMPUTERNAME[count.index]
  location            = var.resource_group[0].location
  resource_group_name = var.resource_group[0].name

  //If no ppg defined do not put the ASCS servers in a proximity placement group
  proximity_placement_group_id = local.ASCS_no_ppg ? (
    null) : (
    local.ASCS_zonal_deployment ? var.ppg[count.index % max(local.ASCS_zone_count, 1)].id : var.ppg[0].id
  )

  //If more than one servers are deployed into a single zone put them in an availability set and not a zone
  availability_set_id = local.use_ASCS_avset ? (
    azurerm_availability_set.ASCS[count.index % max(local.ASCS_zone_count, 1)].id) : (
    null
  )

  //If length of zones > 1 distribute servers evenly across zones
  zone = local.use_ASCS_avset ? (
    null) : (
    try(local.ASCS_zones[count.index % max(local.ASCS_zone_count, 1)], null)
  )

  network_interface_ids = var.application_tier.dual_nics ? (
    var.options.legacy_nic_order ? (
      [
        azurerm_network_interface.ASCS_admin[count.index].id,
        azurerm_network_interface.ASCS[count.index].id
      ]) : (
      [
        azurerm_network_interface.ASCS[count.index].id,
        azurerm_network_interface.ASCS_admin[count.index].id
      ]
    )
    ) : (
    [azurerm_network_interface.ASCS[count.index].id]
  )

  size = length(local.ASCS_size) > 0 ? (
    local.ASCS_size) : (
    local.ASCS_sizing.compute.vm_size
  )
  admin_username = var.sid_username
  admin_password = var.sid_password

  dynamic "os_disk" {
    iterator = disk
    for_each = flatten(
      [
        for storage_type in local.ASCS_sizing.storage : [
          for disk_count in range(storage_type.count) :
          {
            name      = storage_type.name,
            id        = disk_count,
            disk_type = storage_type.disk_type,
            size_gb   = storage_type.size_gb < 128 ? 128 : storage_type.size_gb,
            caching   = storage_type.caching
          }
        ]
        if storage_type.name == "os"
      ]
    )

    content {
      name = format("%s%s%s%s%s",
        var.naming.resource_prefixes.osdisk,
        local.prefix,
        var.naming.separator,
        var.naming.virtualmachine_names.ASCS_VMNAME[count.index],
        local.resource_suffixes.osdisk
      )
      caching                = disk.value.caching
      storage_account_type   = disk.value.disk_type
      disk_size_gb           = disk.value.size_gb
      disk_encryption_set_id = try(var.options.disk_encryption_set_id, null)
    }
  }

  source_image_id = var.application_tier.ASCS_os.type == "custom" ? var.application_tier.ASCS_os.source_image_id : null

  dynamic "source_image_reference" {
    for_each = range(var.application_tier.ASCS_os.type == "marketplace" ? 1 : 0)
    content {
      publisher = var.application_tier.ASCS_os.publisher
      offer     = var.application_tier.ASCS_os.offer
      sku       = var.application_tier.ASCS_os.sku
      version   = var.application_tier.ASCS_os.version
    }
  }

  dynamic "plan" {
    for_each = range(var.application_tier.ASCS_os.type == "marketplace_with_plan" ? 1 : 0)
    content {
      name      = var.application_tier.ASCS_os.offer
      publisher = var.application_tier.ASCS_os.publisher
      product   = var.application_tier.ASCS_os.sku
    }
  }

  boot_diagnostics {
    storage_account_uri = var.storage_bootdiag_endpoint
  }

  #ToDo: Remove once feature is GA  patch_mode = "Manual"
  license_type = length(var.license_type) > 0 ? var.license_type : null

  tags = try(var.application_tier.ASCS_tags, {})
}

# Creates managed data disk
resource "azurerm_managed_disk" "ASCS" {
  provider = azurerm.main
  count    = local.enable_deployment ? length(local.ASCS_data_disks) : 0
  name = format("%s%s%s%s%s",
    var.naming.resource_prefixes.disk,
    local.prefix,
    var.naming.separator,
    var.naming.virtualmachine_names.ASCS_VMNAME[local.ASCS_data_disks[count.index].vm_index],
    local.ASCS_data_disks[count.index].suffix
  )
  location               = var.resource_group[0].location
  resource_group_name    = var.resource_group[0].name
  create_option          = "Empty"
  storage_account_type   = local.ASCS_data_disks[count.index].storage_account_type
  disk_size_gb           = local.ASCS_data_disks[count.index].disk_size_gb
  disk_encryption_set_id = try(var.options.disk_encryption_set_id, null)

  zone = !local.use_ASCS_avset ? (
    upper(var.application_tier.ASCS_os.os_type) == "LINUX" ? (
      azurerm_linux_virtual_machine.ASCS[local.ASCS_data_disks[count.index].vm_index].zone) : (
      azurerm_windows_virtual_machine.ASCS[local.ASCS_data_disks[count.index].vm_index].zone
    )) : (
    null
  )

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azurerm_virtual_machine_data_disk_attachment" "ASCS" {
  provider        = azurerm.main
  count           = local.enable_deployment ? length(local.ASCS_data_disks) : 0
  managed_disk_id = azurerm_managed_disk.ASCS[count.index].id
  virtual_machine_id = upper(var.application_tier.ASCS_os.os_type) == "LINUX" ? (
    azurerm_linux_virtual_machine.ASCS[local.ASCS_data_disks[count.index].vm_index].id) : (
    azurerm_windows_virtual_machine.ASCS[local.ASCS_data_disks[count.index].vm_index].id
  )
  caching                   = local.ASCS_data_disks[count.index].caching
  write_accelerator_enabled = local.ASCS_data_disks[count.index].write_accelerator_enabled
  lun                       = local.ASCS_data_disks[count.index].lun
}

resource "azurerm_virtual_machine_extension" "ASCS_lnx_aem_extension" {
  provider = azurerm.main
  count = local.enable_deployment && upper(var.application_tier.ASCS_os.os_type) == "LINUX" ? (
    local.ASCS_server_count) : (
    0
  )
  name                 = "MonitorX64Linux"
  virtual_machine_id   = azurerm_linux_virtual_machine.ASCS[count.index].id
  publisher            = "Microsoft.AzureCAT.AzureEnhancedMonitoring"
  type                 = "MonitorX64Linux"
  type_handler_version = "1.0"
  settings             = <<SETTINGS
  {
    "system": "SAP"
  }
SETTINGS

  lifecycle {
    ignore_changes = [tags]
  }
}


resource "azurerm_virtual_machine_extension" "ASCS_win_aem_extension" {
  provider = azurerm.main
  count = local.enable_deployment && upper(var.application_tier.ASCS_os.os_type) == "WINDOWS" ? (
    local.ASCS_server_count) : (
    0
  )
  name                 = "MonitorX64Windows"
  virtual_machine_id   = azurerm_windows_virtual_machine.ASCS[count.index].id
  publisher            = "Microsoft.AzureCAT.AzureEnhancedMonitoring"
  type                 = "MonitorX64Windows"
  type_handler_version = "1.0"
  settings             = <<SETTINGS
  {
    "system": "SAP"
  }
SETTINGS
}

resource "azurerm_virtual_machine_extension" "configure_ansible_ASCS" {

  provider = azurerm.main
  count = local.enable_deployment && upper(var.application_tier.ASCS_os.os_type) == "WINDOWS" ? (
    local.ASCS_server_count) : (
    0
  )

  depends_on = [azurerm_virtual_machine_data_disk_attachment.scs]

  virtual_machine_id   = azurerm_windows_virtual_machine.scs[count.index].id
  name                 = "configure_ansible"
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.9"
  settings             = <<SETTINGS
        {
          "fileUris": ["https://raw.githubusercontent.com/ansible/ansible/devel/examples/scripts/ConfigureRemotingForAnsible.ps1"],
          "commandToExecute": "powershell.exe -ExecutionPolicy Unrestricted -File ConfigureRemotingForAnsible.ps1 -Verbose"
        }
    SETTINGS
}

/*
  Description:
  Setup iASCSI related resources, i.e. subnet, nsg, vm, nic, etc.
*/

/*
  Only create/import iASCSI subnet and nsg when iASCSI device(s) will be deployed
*/

// Creates iASCSI subnet of SAP VNET
resource "azurerm_subnet" "iASCSi" {
  provider = azurerm.main
  count    = local.enable_sub_iASCSi ? (local.sub_iASCSi_exists ? 0 : 1) : 0
  name     = local.sub_iASCSi_name
  resource_group_name = local.vnet_sap_exists ? (
    data.azurerm_virtual_network.vnet_sap[0].resource_group_name) : (
    azurerm_virtual_network.vnet_sap[0].resource_group_name
  )
  virtual_network_name = local.vnet_sap_exists ? (
    data.azurerm_virtual_network.vnet_sap[0].name) : (
    azurerm_virtual_network.vnet_sap[0].name
  )
  address_prefixes = [local.sub_iASCSi_prefix]
}

// Imports data of existing SAP iASCSI subnet
data "azurerm_subnet" "iASCSi" {
  provider             = azurerm.main
  count                = local.enable_sub_iASCSi ? (local.sub_iASCSi_exists ? 1 : 0) : 0
  name                 = split("/", local.sub_iASCSi_arm_id)[10]
  resource_group_name  = split("/", local.sub_iASCSi_arm_id)[4]
  virtual_network_name = split("/", local.sub_iASCSi_arm_id)[8]
}

// Creates SAP iASCSI subnet nsg
resource "azurerm_network_security_group" "iASCSi" {
  provider = azurerm.main
  count    = local.enable_sub_iASCSi ? (local.sub_iASCSi_nsg_exists ? 0 : 1) : 0
  name     = local.sub_iASCSi_nsg_name
  location = local.resource_group_exists ? (
    data.azurerm_resource_group.resource_group[0].location) : (
    azurerm_resource_group.resource_group[0].location
  )
  resource_group_name = local.resource_group_exists ? (
    data.azurerm_resource_group.resource_group[0].name) : (
    azurerm_resource_group.resource_group[0].name
  )
}

// Imports the SAP iASCSI subnet nsg data
data "azurerm_network_security_group" "iASCSi" {
  provider            = azurerm.main
  count               = local.enable_sub_iASCSi ? (local.sub_iASCSi_nsg_exists ? 1 : 0) : 0
  name                = split("/", local.sub_iASCSi_nsg_arm_id)[8]
  resource_group_name = split("/", local.sub_iASCSi_nsg_arm_id)[4]
}

// TODO: Add nsr to iASCSI's nsg

/*
  iASCSI device IP address range: .4 - 
*/
// Creates the NIC and IP address for iASCSI device
resource "azurerm_network_interface" "iASCSi" {
  provider = azurerm.main
  count    = local.iASCSi_count
  name = format("%s%s%s%s%s",
    var.naming.resource_prefixes.nic,
    local.prefix,
    var.naming.separator,
    local.virtualmachine_names[count.index],
    local.resource_suffixes.nic
  )
  location = local.resource_group_exists ? (
    data.azurerm_resource_group.resource_group[0].location) : (
  azurerm_resource_group.resource_group[0].location)
  resource_group_name = local.resource_group_exists ? (
    data.azurerm_resource_group.resource_group[0].name) : (
    azurerm_resource_group.resource_group[0].name
  )

  ip_configuration {
    name = "ipconfig1"
    subnet_id = local.sub_iASCSi_exists ? (
      data.azurerm_subnet.iASCSi[0].id) : (
      azurerm_subnet.iASCSi[0].id
    )
    private_ip_address = local.use_DHCP ? (
      null) : (
      local.sub_iASCSi_exists ? (
        local.iASCSi_nic_ips[count.index]) : (
        cidrhost(local.sub_iASCSi_prefix, tonumber(count.index) + 4)
      )
    )
    private_ip_address_allocation = local.use_DHCP ? "Dynamic" : "Static"
  }
}

// Manages the association between NIC and NSG
resource "azurerm_network_interface_security_group_association" "iASCSi" {
  provider             = azurerm.main
  count                = local.iASCSi_count
  network_interface_id = azurerm_network_interface.iASCSi[count.index].id
  network_security_group_id = local.sub_iASCSi_nsg_exists ? (
    data.azurerm_network_security_group.iASCSi[0].id) : (
    azurerm_network_security_group.iASCSi[0].id
  )
}

// Manages Linux Virtual Machine for iASCSI
resource "azurerm_linux_virtual_machine" "iASCSi" {
  provider = azurerm.main
  count    = local.iASCSi_count
  name = format("%s%s%s%s%s",
    var.naming.resource_prefixes.vm,
    local.prefix,
    var.naming.separator,
    local.virtualmachine_names[count.index],
    local.resource_suffixes.vm
  )
  computer_name = local.virtualmachine_names[count.index]
  location = local.resource_group_exists ? (
    data.azurerm_resource_group.resource_group[0].location) : (
    azurerm_resource_group.resource_group[0].location
  )
  resource_group_name = local.resource_group_exists ? (
    data.azurerm_resource_group.resource_group[0].name) : (
    azurerm_resource_group.resource_group[0].name
  )
  network_interface_ids           = [azurerm_network_interface.iASCSi[count.index].id]
  size                            = local.iASCSi.size
  admin_username                  = local.iASCSi.authentication.username
  admin_password                  = local.iASCSi_auth_password
  disable_password_authentication = local.enable_iASCSi_auth_key

  //custom_data = try(data.template_cloudinit_config.config_growpart.rendered, "Cg==")

  os_disk {
    name = format("%s%s%s%s%s",
      var.naming.resource_prefixes.osdisk,
      local.prefix,
      var.naming.separator,
      local.virtualmachine_names[count.index],
      local.resource_suffixes.osdisk
    )
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = local.iASCSi.os.publisher
    offer     = local.iASCSi.os.offer
    sku       = local.iASCSi.os.sku
    version   = "latest"
  }

  dynamic "admin_ssh_key" {
    for_each = range(local.enable_iASCSi_auth_key ? 1 : 0)
    content {
      username   = local.iASCSi_auth_username
      public_key = local.iASCSi_public_key
    }
  }

  boot_diagnostics {
    storage_account_uri = length(var.diagnostics_storage_account.arm_id) > 0 ? (
      data.azurerm_storage_account.storage_bootdiag[0].primary_blob_endpoint) : (
      azurerm_storage_account.storage_bootdiag[0].primary_blob_endpoint
    )
  }

  tags = {
    iASCSiName = local.virtualmachine_names[count.index]
  }
}


// Define a cloud-init config that disables the automatic expansion
// of the root partition.
data "template_cloudinit_config" "config_growpart" {
  gzip          = true
  base64_encode = true

  # Main cloud-config configuration file.
  part {
    content_type = "text/cloud-config"
    content      = "growpart: {'mode': 'auto'}"
  }
}

resource "azurerm_key_vault_secret" "iASCSi_ppk" {
  depends_on = [
    azurerm_key_vault_access_policy.kv_user
  ]
  provider     = azurerm.main
  count        = (local.enable_landscape_kv && local.enable_iASCSi_auth_key && !local.iASCSi_key_exist) ? 1 : 0
  content_type = ""
  name         = local.iASCSi_ppk_name
  value        = local.iASCSi_private_key
  key_vault_id = local.user_keyvault_exist ? local.user_key_vault_id : azurerm_key_vault.kv_user[0].id
}

resource "azurerm_key_vault_secret" "iASCSi_pk" {
  depends_on = [
    azurerm_key_vault_access_policy.kv_user
  ]
  provider     = azurerm.main
  count        = (local.enable_landscape_kv && local.enable_iASCSi_auth_key && !local.iASCSi_key_exist) ? 1 : 0
  content_type = ""
  name         = local.iASCSi_pk_name
  value        = local.iASCSi_public_key
  key_vault_id = local.user_keyvault_exist ? local.user_key_vault_id : azurerm_key_vault.kv_user[0].id
}

resource "azurerm_key_vault_secret" "iASCSi_username" {
  depends_on = [
    azurerm_key_vault_access_policy.kv_user
  ]
  provider     = azurerm.main
  count        = (local.enable_landscape_kv && local.enable_iASCSi && !local.iASCSi_username_exist) ? 1 : 0
  content_type = ""
  name         = local.iASCSi_username_name
  value        = local.iASCSi_auth_username
  key_vault_id = local.user_keyvault_exist ? local.user_key_vault_id : azurerm_key_vault.kv_user[0].id
}

resource "azurerm_key_vault_secret" "iASCSi_password" {
  depends_on = [
    azurerm_key_vault_access_policy.kv_user
  ]
  provider     = azurerm.main
  count        = (local.enable_landscape_kv && local.enable_iASCSi_auth_password && !local.iASCSi_pwd_exist) ? 1 : 0
  content_type = ""
  name         = local.iASCSi_pwd_name
  value        = local.iASCSi_auth_password
  key_vault_id = local.user_keyvault_exist ? local.user_key_vault_id : azurerm_key_vault.kv_user[0].id
}

// Generate random password if password is set as authentication type and user doesn't specify a password, and save in KV
resource "random_password" "iASCSi_password" {
  count = (
    local.enable_landscape_kv
    && local.enable_iASCSi_auth_password
    && !local.iASCSi_pwd_exist
  && try(var.authentication.password, null) == null) ? 1 : 0

  length           = 32
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  special          = true
  override_special = "_%@"
}

// Import secrets about iASCSI
data "azurerm_key_vault_secret" "iASCSi_pk" {
  provider     = azurerm.main
  count        = (local.enable_landscape_kv && local.enable_iASCSi_auth_key && local.iASCSi_key_exist) ? 1 : 0
  name         = local.iASCSi_pk_name
  key_vault_id = local.user_key_vault_id
}

data "azurerm_key_vault_secret" "iASCSi_ppk" {
  provider     = azurerm.main
  count        = (local.enable_landscape_kv && local.enable_iASCSi_auth_key && local.iASCSi_key_exist) ? 1 : 0
  name         = local.iASCSi_ppk_name
  key_vault_id = local.user_key_vault_id
}

data "azurerm_key_vault_secret" "iASCSi_password" {
  provider     = azurerm.main
  count        = (local.enable_landscape_kv && local.enable_iASCSi_auth_password && local.iASCSi_pwd_exist) ? 1 : 0
  name         = local.iASCSi_pwd_name
  key_vault_id = local.user_key_vault_id
}

data "azurerm_key_vault_secret" "iASCSi_username" {
  provider     = azurerm.main
  count        = (local.enable_landscape_kv && local.enable_iASCSi && local.iASCSi_username_exist) ? 1 : 0
  name         = local.iASCSi_username_name
  key_vault_id = local.user_key_vault_id
}

// Using TF tls to generate SSH key pair for iASCSi devices and store in user KV
resource "tls_private_key" "iASCSi" {
  count = (
    local.enable_landscape_kv
    && local.enable_iASCSi_auth_key
    && !local.iASCSi_key_exist
    && try(file(var.authentication.path_to_public_key), null) == null
  ) ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}


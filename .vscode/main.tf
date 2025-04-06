provider "azurerm" {
features {}

subscription_id = "28d04284-c72f-4f90-9316-995c3e2a8435"
}


resource "azurerm_resource_group" "rg" {
name     = "axa-pfe-rg"
location = "westeurope"
}


variable "vm_names" {
default = ["vm-orchestrator", "vm-dynatrace", "vm-automation", "vm-backup"]
}


resource "azurerm_virtual_network" "vnet" {
name                = "axa-pfe-vnet"
address_space       = ["10.0.0.0/16"]
location            = azurerm_resource_group.rg.location
resource_group_name = azurerm_resource_group.rg.name
}


resource "azurerm_subnet" "subnet" {
name                 = "axa-pfe-subnet"
resource_group_name  = azurerm_resource_group.rg.name
virtual_network_name = azurerm_virtual_network.vnet.name
address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_public_ip" "dynatrace_ip" {
  name                = "pip-axa-pfe-vnet-westeurope-axa-pfe-subnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_public_ip" "public_ip" {
name                = "vm-orchestrator-pip"
location            = azurerm_resource_group.rg.location
resource_group_name = azurerm_resource_group.rg.name
allocation_method   = "Static"
sku                 = "Standard"
}


resource "azurerm_network_interface" "nic" {
count               = length(var.vm_names)
name                = "${var.vm_names[count.index]}-nic"
location            = azurerm_resource_group.rg.location
resource_group_name = azurerm_resource_group.rg.name

ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    

  public_ip_address_id = (
  var.vm_names[count.index] == "vm-orchestrator" ? azurerm_public_ip.public_ip.id :
  var.vm_names[count.index] == "vm-dynatrace"    ? azurerm_public_ip.dynatrace_ip.id :
  null
)

}
lifecycle {
    ignore_changes = [
    ip_configuration[0].public_ip_address_id
    ]
}
}

resource "azurerm_virtual_machine" "vm_linux" {
count               = length(var.vm_names)
name                = var.vm_names[count.index]
location            = azurerm_resource_group.rg.location
resource_group_name = azurerm_resource_group.rg.name
vm_size = (count.index == 1 || count.index == 0) ? "Standard_B1ms" : "Standard_B1s"

identity {
    type = "SystemAssigned" 
  }

storage_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
}

storage_os_disk {
    name              = "${var.vm_names[count.index]}-osdisk"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
}

os_profile {
    computer_name  = var.vm_names[count.index]
    admin_username = "adminuser"
    admin_password = "ComplexP@ssw0rd!"
}

os_profile_linux_config {  
    disable_password_authentication = false
}

network_interface_ids = [
    azurerm_network_interface.nic[count.index].id,
]

delete_os_disk_on_termination = true
}
resource "azurerm_public_ip" "activegate_lb_pip" {
  name                = "activegate-lb-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}
resource "azurerm_lb" "activegate_lb" {
  name                = "activegate-loadbalancer"
  location            = "westeurope"
  resource_group_name = "axa-pfe-rg"
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "activegate-frontend-ip"
    public_ip_address_id = azurerm_public_ip.activegate_lb_pip.id
  }
}

resource "azurerm_lb_backend_address_pool" "activegate_pool" {
  loadbalancer_id = azurerm_lb.activegate_lb.id
  name            = "activegate-backend-pool"
}
resource "azurerm_lb_probe" "activegate_probe" {
  loadbalancer_id = azurerm_lb.activegate_lb.id
  name            = "activegate-health-probe"
  port            = 9999
  protocol        = "Tcp"
}
resource "azurerm_lb_rule" "activegate_rule" {
  loadbalancer_id                = azurerm_lb.activegate_lb.id
  name                           = "activegate-lb-rule"
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 9999
  frontend_ip_configuration_name = "activegate-frontend-ip"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.activegate_pool.id]
  probe_id                       = azurerm_lb_probe.activegate_probe.id
}

resource "azurerm_network_security_group" "nsg_ag" {
  name                = "nsg-activegate"
  location            = "westeurope"
  resource_group_name = "axa-pfe-rg"

  security_rule {
    name                       = "AllowSSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowAGPorts"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["443", "9999"]
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
  
  security_rule {
    name                       = "AllowAzureHealthProbe"
    priority                   = 1012
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "168.63.129.16"
    destination_port_ranges    = ["22", "3389"]
    source_port_range          = "*"
    destination_address_prefix = "*"
  }
}


resource "azurerm_network_interface_backend_address_pool_association" "ag1_lb_assoc" {
  network_interface_id    = azurerm_network_interface.nic[0].id  
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.activegate_pool.id
}

resource "azurerm_network_interface_backend_address_pool_association" "ag2_lb_assoc" {
  network_interface_id    = azurerm_network_interface.nic[1].id  
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.activegate_pool.id
}
resource "azurerm_network_interface_security_group_association" "nic_nsg_assoc" {
  count                     = length(var.vm_names)
  network_interface_id      = azurerm_network_interface.nic[count.index].id
  network_security_group_id = azurerm_network_security_group.nsg_ag.id
}

terraform {
  backend "azurerm" {
    resource_group_name  = "axa-pfe-rg"
    storage_account_name = "terraformpipelinedevops"
    container_name       = "terraform-state"
    key                  = "terraform.tfstate"
  }
}

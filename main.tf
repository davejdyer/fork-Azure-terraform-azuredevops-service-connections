# ------
# BASICS
# ------
# Get information about the current Azure subscription
data "azurerm_subscription" "current" {}
data "azurerm_client_config" "current" {}

# --------
# AZURE AD
# --------

# Gets information about Application and SPN owners
data "azuread_users" "owners" {
  for_each = var.service_principals

  user_principal_names = concat(var.default_owners, each.value.owners)
}

# Create the application
resource "azurerm_azuread_application" "main" {
  for_each = var.service_principals

  display_name = each.key
  owners       = concat([data.azurerm_client_config.current.object_id], data.azuread_users.owners[each.key].object_ids)

  lifecycle {
    ignore_changes = [
      required_resource_access # If API permissions are given outside Terraform, don't change them
    ]
  }
}

# Create the service principal
resource "azurerm_azuread_service_principal" "main" {
  for_each = var.service_principals

  application_id = azuread_application.main[each.key].application_id
  owners         = concat([data.azurerm_client_config.current.object_id], data.azuread_users.owners[each.key].object_ids)
}

# Create time_rotating resource to use in azuread_application_password
resource "time_rotating" "aad_application_password_main" {
  for_each = { for k, v in var.service_principals : k => v if v.auto_rotate_client_secret == true } # Only create if 'auto_rotate_client_secret' is 'true'.

  rotation_days = each.value.client_secret_rotation_interval_in_days
}

# Create client secret
resource "azuread_application_password" "main" {
  for_each = var.service_principals

  application_object_id = azuread_application.main[each.key].id
  display_name          = "Generated by Terraform"

  rotate_when_changed = {
    rotation = each.value.auto_rotate_client_secret == true ? time_rotating.aad_application_password_main[each.key].id : null
  }
}


# ---------------------
# AZURE ROLE ASSIGNMENT
# ---------------------
# Assigning role on Azure resource
resource "azurerm_role_assignment" "main" {
  for_each = { for k, v in var.service_principals : k => v if v.create_azure_role_assignment == true || v.create_azure_devops_service_connection == true } # Only create if 'create_azure_role_assignment' is 'true' or 'create_azure_devops_service_connection' is 'true'.

  principal_id = azuread_service_principal.main[each.key].object_id

  # If no scope is configured, the scope will be set to subscription scope.
  scope                = each.value.azure_role_assignment_scope != null ? each.value.azure_role_assignment_scope : "/subscriptions/${data.azurerm_subscription.current.subscription_id}"
  role_definition_name = each.value.azure_role_assignment_name
}


# ------------
# AZURE DEVOPS
# ------------

# Get information about Azure DevOps project
data "azuredevops_project" "main" {
  for_each = { for k, v in var.service_principals : k => v if v.create_azure_devops_service_connection == true } # Only create if 'create_azure_devops_service_connection' is 'true'.

  # If Azure DevOps project name is configured in the map, use that value, if not use the value from the variable holding the default value
  name = each.value.azuredevops_project_name != null ? each.value.azuredevops_project_name : var.default_azuredevops_project_name
}

# Create service connection in Azure DevOps
resource "azuredevops_serviceendpoint_azurerm" "main" {
  for_each = { for k, v in var.service_principals : k => v if v.create_azure_devops_service_connection == true } # Only create if 'create_azure_devops_service_connection' is 'true'.

  service_endpoint_name = azuread_application.main[each.key].display_name
  project_id            = data.azuredevops_project.main[each.key].id

  azurerm_spn_tenantid      = data.azurerm_subscription.current.tenant_id
  azurerm_subscription_id   = data.azurerm_subscription.current.subscription_id
  azurerm_subscription_name = data.azurerm_subscription.current.display_name

  credentials {
    serviceprincipalid  = azuread_application.main[each.key].application_id
    serviceprincipalkey = azuread_application_password.main[each.key].value
  }

  depends_on = [
    azurerm_role_assignment.main
  ]

  lifecycle {
    ignore_changes = [
      environment
    ]
  }
}

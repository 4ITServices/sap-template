variable "environment" {
  type        = string
  description = "Environment name (dev, prd)"

  validation {
    condition     = contains(["dev", "prd"], var.environment)
    error_message = "environment must be 'dev' or 'prd'"
  }
}

variable "subscription_id" {
  type        = string
  description = "Azure subscription ID"
}

variable "location" {
  type        = string
  default     = "francecentral"
  description = "Azure region"
}

variable "project" {
  type        = string
  description = "Project short name (used in resource naming)"
}

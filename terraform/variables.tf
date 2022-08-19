/* -------------------------- */
/* -------- VARIABLES ------- */
/* -------------------------- */

# Resource naming convention (exceptions apply): prefix-${var.app}-${terraform.workspace}
# Create and set Terraform workspaces with terraform workspace new & terraform workspace select, for example:
# terraform workspace new dev

# Google Cloud project id
variable "project" {
  type = string
  default = "your-gcp-project-id"
}

# App name used in resource naming
variable "app" {
    type = string
    default = "adenotifier234"
}

# GCP region
# Edit regions/zones according to your requirements.
# Note that all resource types are not available in all regions.
variable "region" {
    type = string
    default = "europe-west1"
}

# GCP zone
variable "zone" {
    type = string
    default = "europe-west1-b"
}

# Secret manager replica region
variable "replica_region" {
    type = string
    default = "europe-north1"
}

# GCP bucket location
variable "storage_location" {
    type = string
    default = "EU"
}

# Network CIDR range
variable "cidr_range" {
    type = string
    default = "10.8.0.0/28"
}

# Prefix added to notified file URLs
# Use "gs://" for BigQuery
# Use "gcs://" for Snowflake
variable "file_url_prefix" {
    type = string
    default = "gs://"
}

# Source data bucket name
# Modify the templates if you are deploying multiple environments with different source data buckets.
variable "source_data_bucket" {
    type = string
    default = "your-source-data-bucket"
}

# Path to source data within bucket
# Used to filter Pub/Sub events.
# Set as null to catch events from entire bucket.
variable "source_data_object_prefix" {
    type = string
    default = null
}
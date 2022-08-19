/* -------------------------- */
/* --- TERRAFORM PROVIDER --- */
/* -------------------------- */

terraform {
  required_providers {
    # 2nd gen Cloud Functions were only supported in the beta provider at the time of creating this template
    google = {
      source  = "hashicorp/google-beta" 
      version = "4.31.0"
    }
  }
  /* OPTIONAL: Configure Terraform remote state
  backend "gcs" {
    bucket  = "bucket-name-here"
    prefix  = "terraform/state"
  }
  */
}

provider "google" {
  project = var.project
  region  = var.region
  zone    = var.zone
}


/* -------------------------- */
/* ---- SERVICE ACCOUNT ----- */
/* -------------------------- */

# Service account
resource "google_service_account" "account" {
  project = var.project
  account_id = "sa-${var.app}-${terraform.workspace}"
  display_name = "Service account for ${var.app}-${terraform.workspace}"
}

# Role grants
resource "google_project_iam_member" "run_invoker" {
  role    = "roles/run.invoker"
  project = var.project
  member  = "serviceAccount:${google_service_account.account.email}"
}
resource "google_project_iam_member" "event_receiver" {
  role    = "roles/eventarc.eventReceiver"
  project = var.project
  member  = "serviceAccount:${google_service_account.account.email}"
}
resource "google_project_iam_member" "artifactregistry_reader" {
  role    = "roles/artifactregistry.reader"
  project = var.project
  member  = "serviceAccount:${google_service_account.account.email}"
}


/* -------------------------- */
/* --------- STORAGE -------- */
/* -------------------------- */

# Notifier configuration bucket
resource "google_storage_bucket" "notifierbucket" {
  name = "${var.app}-${terraform.workspace}"
  location = var.storage_location
  storage_class = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy = true
}

# Bucket IAM binding
resource "google_storage_bucket_iam_binding" "notifierbucket_binding" {
  bucket = google_storage_bucket.notifierbucket.name
  role = "roles/storage.objectViewer"
  members = ["serviceAccount:${google_service_account.account.email}"]
}

# Data source configuration file
resource "google_storage_bucket_object" "configfile" {
  name   = "datasource-config/datasources.json"
  bucket = google_storage_bucket.notifierbucket.name
  source = "${path.root}/../configuration/datasources.json"
}

# Function zip archive
data "archive_file" "function_archive" {
  type        = "zip"
  source_dir  = "${path.root}/../functions/"
  output_path = "${path.root}/.output/functions.zip"
}

# Function zip archive bucket object
resource "google_storage_bucket_object" "function_object" {
  name   = "functions/${data.archive_file.function_archive.output_md5}.zip"
  bucket = google_storage_bucket.notifierbucket.name
  source = data.archive_file.function_archive.output_path
}


/* -------------------------- */
/* --------- PUB/SUB -------- */
/* -------------------------- */

# Topic: add_to_manifest
resource "google_pubsub_topic" "add_to_manifest_topic" {
  name = "pst-${var.app}-add-to-manifest-${terraform.workspace}"
}

# Topic: notify_manifest
resource "google_pubsub_topic" "notify_manifest_topic" {
  name = "pst-${var.app}-notify-manifest-${terraform.workspace}"
}

# Topic IAM bindings
data "google_storage_project_service_account" "gcs_account" {
}
resource "google_pubsub_topic_iam_binding" "add_to_manifest_binding" {
  topic   = google_pubsub_topic.add_to_manifest_topic.id
  role    = "roles/pubsub.publisher"
  members = ["serviceAccount:${data.google_storage_project_service_account.gcs_account.email_address}"]
}
resource "google_pubsub_topic_iam_binding" "notify_manifest_binding" {
  topic   = google_pubsub_topic.notify_manifest_topic.id
  role    = "roles/pubsub.publisher"
  members = ["serviceAccount:${data.google_storage_project_service_account.gcs_account.email_address}"]
}

# Storage notification: add_to_manifest
resource "google_storage_notification" "notification" {
  bucket         = var.source_data_bucket
  payload_format = "JSON_API_V1"
  topic          = google_pubsub_topic.add_to_manifest_topic.id
  event_types    = ["OBJECT_FINALIZE", "OBJECT_METADATA_UPDATE"]
  object_name_prefix = var.source_data_object_prefix
  depends_on = [google_pubsub_topic_iam_binding.add_to_manifest_binding]
}


/* -------------------------- */
/* --------- NETWORK -------- */
/* -------------------------- */

# VPC
resource "google_compute_network" "cloud_function_network" {
  name = "vpc-${var.app}-${terraform.workspace}"
  auto_create_subnetworks = false
}

# VPC connector
resource "google_vpc_access_connector" "connector" {
  name          = "vpcac-${var.app}-${terraform.workspace}"
  region        = var.region
  ip_cidr_range = var.cidr_range
  network       = google_compute_network.cloud_function_network.name
}

# IP address
resource "google_compute_address" "egress_ip_address" {
  name    = "ip-${var.app}-${terraform.workspace}"
  region  = var.region
}

# Router
resource "google_compute_router" "router" {
  name    = "gcr-${var.app}-${terraform.workspace}"
  region  = var.region
  network = google_compute_network.cloud_function_network.name
}

# NAT
resource "google_compute_router_nat" "cloud_function_nat" {
  name  = "nat-${var.app}-${terraform.workspace}"
  router = google_compute_router.router.name
  region = google_compute_router.router.region
  nat_ip_allocate_option = "MANUAL_ONLY"
  nat_ips = google_compute_address.egress_ip_address.*.self_link

  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}


/* -------------------------- */
/* ------- FUNCTIONS -------- */
/* -------------------------- */

# Cloud function: add_to_manifest
resource "google_cloudfunctions2_function" "add_to_manifest_function" {
  name = "gcf-${var.app}-add-to-manifest-${terraform.workspace}"
  location = var.region
  build_config {
    runtime = "python310"
    entry_point = "add_to_manifest"
    source {
      storage_source {
        bucket = google_storage_bucket.notifierbucket.name
        object = google_storage_bucket_object.function_object.name
      }
    }
  }
  service_config {
    timeout_seconds = 60
    available_memory = "256M"
    environment_variables = {
      NOTIFY_API_SECRET_ID = google_secret_manager_secret.notify_api.name
      BUCKET_NAME = google_storage_bucket.notifierbucket.name
      FILE_URL_PREFIX = var.file_url_prefix
    }
    vpc_connector = google_vpc_access_connector.connector.name
    vpc_connector_egress_settings = "ALL_TRAFFIC"
    max_instance_count = 1
    service_account_email = google_service_account.account.email
  }
  event_trigger {
    event_type = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic = google_pubsub_topic.add_to_manifest_topic.id
    retry_policy = "RETRY_POLICY_RETRY"
    trigger_region = var.region
    service_account_email = google_service_account.account.email
  }
}

# Cloud function: notify_manifest
resource "google_cloudfunctions2_function" "notify_manifest_function" {
  name = "gcf-${var.app}-notify-manifest-${terraform.workspace}"
  location = var.region
  build_config {
    runtime = "python310"
    entry_point = "notify_manifest"
    source {
      storage_source {
        bucket = google_storage_bucket.notifierbucket.name
        object = google_storage_bucket_object.function_object.name
      }
    }
  }
  service_config {
    timeout_seconds = 60
    available_memory = "256M"
    environment_variables = {
      NOTIFY_API_SECRET_ID = google_secret_manager_secret.notify_api.name
      BUCKET_NAME = google_storage_bucket.notifierbucket.name
      FILE_URL_PREFIX = var.file_url_prefix
    }
    vpc_connector = google_vpc_access_connector.connector.name
    vpc_connector_egress_settings = "ALL_TRAFFIC"
    max_instance_count = 1
    service_account_email = google_service_account.account.email
  }
  event_trigger {
    event_type = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic = google_pubsub_topic.notify_manifest_topic.id
    retry_policy = "RETRY_POLICY_RETRY"
    trigger_region = var.region
    service_account_email = google_service_account.account.email
  }
}


/* -------------------------- */
/* ----- SECRET MANAGER ----- */
/* -------------------------- */

# Notify API secret
resource "google_secret_manager_secret" "notify_api" {
  secret_id = "notify_api_${terraform.workspace}"
  replication {
    user_managed {
      replicas {
        location = var.replica_region
      }
    }
  }
}

# Secret IAM binding
data "google_project" "project" {}
resource "google_secret_manager_secret_iam_binding" "binding" {
  project = var.project
  secret_id = google_secret_manager_secret.notify_api.secret_id
  role = "roles/secretmanager.secretAccessor"
  members = ["serviceAccount:${google_service_account.account.email}"]
}
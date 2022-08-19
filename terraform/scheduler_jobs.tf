/* -------------------------- */
/* ----- SCHEDULER JOBS ----- */
/* -------------------------- */

# Configure scheduler jobs for notifying data sources where single_file_manifest = false. 
# Scheduler job will trigger the notify_manifest function which will notify (close) open manifests for listed data sources.
resource "google_cloud_scheduler_job" "example_1" {
    name        = "${var.app}-${terraform.workspace}-example-1"
    description = "Notifier example schedule 1"
    schedule    = "0 2 * * *"
    region      = var.region
    pubsub_target {
        topic_name = google_pubsub_topic.notify_manifest_topic.id
        data       = base64encode("[\"example_source/example_entity_1\", \"example_source/example_entity_2\"]")
    }
}
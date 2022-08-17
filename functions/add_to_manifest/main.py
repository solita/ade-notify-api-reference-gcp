import functions_framework
import os
import json
import base64
import logging
import google.cloud.logging
from google.cloud import storage
from google.cloud import secretmanager
from adenotifier import notifier

def get_configuration(config_bucket: str, config_file: str):
    """Loads a configuration file from a storage bucket.

    Args:
        config_bucket (str): Bucket name where configuration file is stored.
        config_file (str): Configuration file path.

    Returns:
        Configuration file as JSON object.

    """

    storage_client = storage.Client()
    bucket = storage_client.bucket(config_bucket)
    blob = bucket.blob(config_file)
    
    return json.loads(blob.download_as_string())

def get_secret(secret_id: str):
    """Gets Notify API secret from Secret Manager.

    Args:
        secret_id (str): Secret id, e.g. "projects/{project_id}/secrets/{secret_id}".

    Returns:
        Latest version of secret value as JSON object.

    """
    client = secretmanager.SecretManagerServiceClient()
    response = client.access_secret_version(name = f'{secret_id}/versions/latest')
    
    return json.loads(response.payload.data.decode("UTF-8"))


def identify_sources(file_url: str, config: object):
    """Compares a file url to the data source configuration to find matches.

    Args:
        file_url (str): File url.
        config (object): Data source configuration file as JSON object.

    Returns:
        List of matched sources.

    """

    sources = []
    
    for source in config:
        source_bucket = source['attributes']['storage_bucket']
        source_path = source['attributes']['folder_path']
        
        # Optional attribute
        if ('file_extension' in source['attributes']):
            source_extension = source['attributes']['file_extension']
        else:
            source_extension = ""

        if (f'{source_bucket}/{source_path}' in file_url and source_extension in file_url):
            sources.append(source)

    return sources

@functions_framework.cloud_event
def main(cloud_event: object) -> None:
    """Triggered by a cloud event.
    Gets configuration, identifies data source, adds file to a manifest if source is identified.
        
    Args:
        cloud_event (functions_framework.cloud_event): Google cloud event which triggers the function.

    Returns:
        None.

    """
    # Using Python logging
    client = google.cloud.logging.Client()
    client.setup_logging()

    event_data = json.loads(base64.b64decode(cloud_event.data['message']['data']).decode())
    logging.info(f'Cloud Function was triggered by Pub/Sub event:\n{event_data}')
    event_url = f"{os.environ['FILE_URL_PREFIX']}{event_data['bucket']}/{event_data['name']}"

    # Get configuration file ({bucket}/datasource-config/datasources.json)
    config = get_configuration(config_bucket = os.environ['BUCKET_NAME'], config_file = "datasource-config/datasources.json")

    # Identify data sources
    sources = identify_sources(event_url, config)
    
    if (sources == []):
        logging.info(f'Source not identified for url: {event_url}')
        return

    # Get secrets
    secrets = get_secret(os.environ['NOTIFY_API_SECRET_ID'])
    
    # Manifests
    for source in sources:
        logging.info(f"Processing source: {source['id']}")
        notifier.add_to_manifest(event_url, source, secrets['base_url'], secrets['api_key'], secrets['api_key_secret'])

    return
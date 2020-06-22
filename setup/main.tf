/* ========================================================================== */
/*                                   Project                                  */
/* ========================================================================== */

# Module:
# https://github.com/terraform-google-modules/terraform-google-project-factory/tree/master/modules/project_services

module "project-services" {
  source  = "terraform-google-modules/project-factory/google//modules/project_services"
  version = "4.0.0"

  project_id = var.project_id

  activate_apis = [
    "serviceusage.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "vpcaccess.googleapis.com",
    "run.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "appengine.googleapis.com",
    "appengine-flexible.googleapis.com",
    "containerregistry.googleapis.com",
    "container.googleapis.com",
    "sql-component.googleapis.com",
    "storage-component.googleapis.com",
    "storage-api.googleapis.com"
  ]
}

resource "google_service_account" "default" {
  account_id   = "se7en-apps"
  display_name = "7-Apps-7-Minutes Service Account"
}

/* ========================================================================== */
/*                                 VPC Network                                */
/* ========================================================================== */

/* VPC ---------------------------------------------------------------------- */

resource "google_compute_network" "default" {
  project = var.project_id
  name    = var.network_name

  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "default" {
  name                     = "${var.network_name}-subnet"
  ip_cidr_range            = "10.21.12.0/24"
  network                  = google_compute_network.default.self_link
  region                   = var.region
  private_ip_google_access = true
}

/* Serverless VPC Access ---------------------------------------------------- */

# https://cloud.google.com/vpc/docs/configure-serverless-vpc-access

resource "google_vpc_access_connector" "connector" {
  name          = "connector-${google_compute_subnetwork.default.name}"
  project       = var.project_id
  network       = google_compute_network.default.self_link
  region        = var.region
  ip_cidr_range = "10.1.1.0/24"
}

/* Private Services Access ------------------------------------------------ */

# https://cloud.google.com/vpc/docs/configure-private-services-access

resource "google_compute_global_address" "google_services" {
  network       = google_compute_network.default.self_link
  name          = "ip-google-services"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
}

resource "google_service_networking_connection" "google_services" {
  network                 = google_compute_network.default.self_link
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.google_services.name]
}


/* Firewall ----------------------------------------------------------------- */

locals {
  firewall_allow_ranges = ["0.0.0.0/0"]
}

# Module:
# https://github.com/terraform-google-modules/terraform-google-network/tree/master/modules/fabric-net-firewall

module "firewall" {
  source = "terraform-google-modules/network/google//modules/fabric-net-firewall"

  project_id = var.project_id
  network    = google_compute_network.default.self_link

  http_source_ranges  = local.firewall_allow_ranges
  https_source_ranges = local.firewall_allow_ranges
  ssh_source_ranges   = local.firewall_allow_ranges

  internal_ranges_enabled = true
  internal_ranges = flatten([
    google_compute_subnetwork.default.ip_cidr_range,
    google_vpc_access_connector.connector.ip_cidr_range,
    google_container_cluster.gke.private_cluster_config.*.master_ipv4_cidr_block,
  ])
  internal_allow = [
    { "protocol": "icmp" },
    { "protocol": "tcp" }
  ]
}

/* ========================================================================== */
/*                                  Cloud DNS                                 */
/* ========================================================================== */

resource "google_dns_managed_zone" "dns" {
  name        = "7apps"
  description = "Public DNS zone for 7apps.servian.fun"
  dns_name    = "${var.domain_name}."
}

/* ========================================================================== */
/*                                  Cloud SQL                                 */
/* ========================================================================== */

locals {
  db_name     = "7apps"
  db_user     = "7apps"
  db_password = module.cloudsql.generated_user_password
}

# Module:
# https://github.com/terraform-google-modules/terraform-google-sql-db

module "cloudsql" {
  source  = "GoogleCloudPlatform/sql-db/google//modules/postgresql"
  version = "3.2.0"

  name             = "postgres-db"
  project_id       = var.project_id
  region           = var.region
  zone             = "${var.region}-b"
  database_version = "POSTGRES_12"
  tier             = "e2-small"

  db_name       = local.db_name
  user_name     = local.db_user

  ip_configuration = {
    ipv4_enabled        = true
    private_network     = google_compute_network.default.self_link
    authorized_networks = []
    require_ssl         = false
  }

  module_depends_on = [google_service_networking_connection.google_services]
}

/* ========================================================================== */
/*                                 App Engine                                 */
/* ========================================================================== */

/* App ---------------------------------------------------------------------- */

resource "google_app_engine_application" "app" {
  project     = var.project_id
  location_id = var.region
}

resource "google_storage_bucket" "app" {
  name = "7apps-appengine"
}

/* Routing Rules ------------------------------------------------------------ */

# https://cloud.google.com/appengine/docs/standard/python/reference/dispatch-yaml

resource "google_app_engine_application_url_dispatch_rules" "app" {
  dispatch_rules {
    domain  = var.appengine_standard_subdomain
    path    = "/*"
    service = "standard"
  }

  dispatch_rules {
    domain  = var.appengine_flexible_subdomain
    path    = "/*"
    service = "flexible"
  }

  dispatch_rules {
    domain  = var.domain_name
    path    = "/*"
    service = "default"
  }
}

/* Default Service (Monitoring Dashboard) ----------------------------------- */

data "archive_file" "monitoring_dashboard" {
  type        = "zip"
  source_dir = "${path.module}/assets/monitoring_dashboard"
  output_path = "${path.module}/assets/monitoring_dashboard.zip"
}

resource "google_storage_bucket_object" "default" {
  name   = basename(data.archive_file.monitoring_dashboard.output_path)
  bucket = google_storage_bucket.app.name
  source = data.archive_file.monitoring_dashboard.output_path
}

resource "google_app_engine_standard_app_version" "default" {
  project    = var.project_id
  service    = "standard"
  runtime    = "python37"
  version_id = "initial"

  deployment {
    zip {
      source_url = google_storage_bucket_object.default.self_link
    }
  }

  basic_scaling {
    max_instances = 1
    idle_timeout = 300
  }

  delete_service_on_destroy = true
}

/* DNS ---------------------------------------------------------------------- */

# https://cloud.google.com/appengine/docs/standard/python/mapping-custom-domains

resource "google_app_engine_domain_mapping" "default" {
  domain_name = var.domain_name

  ssl_settings {
    ssl_management_type = "AUTOMATIC"
  }
}

resource "google_app_engine_domain_mapping" "wildcard" {
  domain_name = "*.${var.domain_name}"

  ssl_settings {
    ssl_management_type = "AUTOMATIC"
  }
}

resource "google_dns_record_set" "appengine_default" {
  for_each     = google_app_engine_domain_mapping.default.resource_records

  name         = "${var.domain_name}."
  managed_zone = google_dns_managed_zone.dns.name
  type         = each.value.type
  rrdatas      = each.value.rrdata
  ttl          = 300

  depends_on = [google_app_engine_domain_mapping.default]
}

resource "google_dns_record_set" "appengine_wildcard" {
  for_each     = google_app_engine_domain_mapping.wildcard.resource_records

  name         = "*.${var.domain_name}."
  managed_zone = google_dns_managed_zone.dns.name
  type         = each.value.type
  rrdatas      = each.value.rrdata
  ttl          = 300

  depends_on = [google_app_engine_domain_mapping.wildcard]
}
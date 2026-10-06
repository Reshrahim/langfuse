extension radius

param environment string

param nextAuthUrl string

@secure()
param clickhousePassword string

@secure()
param encryptionKey string

@secure()
param nextAuthSecret string

@secure()
param postgresPassword string

@secure()
param registryPassword string

@secure()
param registryUsername string

@secure()
param salt string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'langfuse'
  properties: {
    environment: environment
  }
}

resource clickhouseData 'Radius.Compute/persistentVolumes@2025-08-01-preview' = {
  name: 'clickhouse-data'
  properties: {
    environment: environment
    application: app.id
    allowedAccessModes: 'ReadWriteOnce'
    codeReference: 'docker-compose.yml#L106'
    sizeInGib: 32
  }
}

resource objectStore 'Radius.Storage/objectStorage@2025-08-01-preview' = {
  name: 'object-storage'
  properties: {
    environment: environment
    application: app.id
    codeReference: 'packages/shared/src/server/services/StorageService.ts#L384'
    containerName: 'langfuse'
  }
}

resource postgresDb 'Radius.Data/postgreSqlDatabases@2025-08-01-preview' = {
  name: 'postgres'
  properties: {
    environment: environment
    application: app.id
    codeReference: 'packages/shared/src/db.ts#L23'
    database: 'langfuse'
    password: postgresPassword
    tls: 'required'
    username: 'myadmin'
  }
}

resource redisCache 'Radius.Data/redisCaches@2025-08-01-preview' = {
  name: 'redis'
  properties: {
    environment: environment
    application: app.id
    codeReference: 'packages/shared/src/server/redis/redis.ts#L184'
  }
}

resource appSecrets 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'langfuse-secrets'
  properties: {
    environment: environment
    application: app.id
    codeReference: 'packages/shared/src/env.ts#L96'
    data: {
      clickhousePassword: {
        value: clickhousePassword
      }
      databasePassword: {
        value: postgresPassword
      }
      encryptionKey: {
        value: encryptionKey
      }
      nextAuthSecret: {
        value: nextAuthSecret
      }
      salt: {
        value: salt
      }
    }
  }
}

// Do not change this Secret's name value from 'radius-ghcr-registry-creds'.
// The containerImages recipe looks up registry credentials by that fixed name.
resource registryCreds 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'radius-ghcr-registry-creds'
  properties: {
    environment: environment
    application: app.id
    codeReference: '.radius/app.bicep#L106'
    data: {
      username: {
        value: registryUsername
      }
      password: {
        value: registryPassword
      }
    }
  }
}

resource webImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'web-image'
  properties: {
    environment: environment
    application: app.id
    codeReference: 'web/Dockerfile'
    tag: 'f1206115'
    build: {
      source: 'git::https://github.com/Reshrahim/langfuse.git?ref=f1206115b29d8ddc83a51350834ccd7f8c2fba2f'
      dockerfile: 'web/Dockerfile'
      platforms: [
        'linux/amd64'
      ]
    }
  }
  dependsOn: [
    registryCreds
  ]
}

resource workerImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'worker-image'
  properties: {
    environment: environment
    application: app.id
    codeReference: 'worker/Dockerfile'
    tag: 'f1206115'
    build: {
      source: 'git::https://github.com/Reshrahim/langfuse.git?ref=f1206115b29d8ddc83a51350834ccd7f8c2fba2f'
      dockerfile: 'worker/Dockerfile'
      platforms: [
        'linux/amd64'
      ]
    }
  }
  dependsOn: [
    registryCreds
  ]
}

resource clickhouseContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'clickhouse'
  properties: {
    environment: environment
    application: app.id
    codeReference: '.radius/app.bicep#L163'
    containers: {
      clickhouse: {
        image: 'docker.io/clickhouse/clickhouse-server:25.12'
        env: {
          CLICKHOUSE_DB: {
            value: 'default'
          }
          CLICKHOUSE_PASSWORD: {
            valueFrom: {
              secretKeyRef: {
                secretName: appSecrets.name
                key: 'clickhousePassword'
              }
            }
          }
          CLICKHOUSE_USER: {
            value: 'clickhouse'
          }
        }
        ports: {
          http: {
            containerPort: 8123
          }
          native: {
            containerPort: 9000
          }
        }
        readinessProbe: {
          httpGet: {
            path: '/ping'
            port: 8123
          }
        }
        volumeMounts: [
          {
            volumeName: 'data'
            mountPath: '/var/lib/clickhouse'
          }
        ]
      }
    }
    volumes: {
      data: {
        persistentVolume: {
          accessMode: 'ReadWriteOnce'
          resourceId: clickhouseData.id
        }
      }
    }
  }
}

resource webContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'web'
  properties: {
    environment: environment
    application: app.id
    codeReference: 'web/src/pages/_app.tsx'
    containers: {
      web: {
        image: webImage.properties.imageReference
        env: {
          CLICKHOUSE_CLUSTER_ENABLED: {
            value: 'false'
          }
          CLICKHOUSE_MIGRATION_URL: {
            value: 'clickhouse://${clickhouseContainer.properties.hosts.clickhouse}:9000'
          }
          CLICKHOUSE_PASSWORD: {
            valueFrom: {
              secretKeyRef: {
                secretName: appSecrets.name
                key: 'clickhousePassword'
              }
            }
          }
          CLICKHOUSE_URL: {
            value: 'http://${clickhouseContainer.properties.hosts.clickhouse}:8123'
          }
          CLICKHOUSE_USER: {
            value: 'clickhouse'
          }
          DATABASE_ARGS: {
            value: 'sslmode=require'
          }
          DATABASE_HOST: {
            value: postgresDb.properties.host
          }
          DATABASE_NAME: {
            value: 'langfuse'
          }
          DATABASE_PASSWORD: {
            valueFrom: {
              secretKeyRef: {
                secretName: appSecrets.name
                key: 'databasePassword'
              }
            }
          }
          DATABASE_USERNAME: {
            value: 'myadmin'
          }
          ENCRYPTION_KEY: {
            valueFrom: {
              secretKeyRef: {
                secretName: appSecrets.name
                key: 'encryptionKey'
              }
            }
          }
          LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID: {
            value: objectStore.properties.accountName
          }
          LANGFUSE_S3_EVENT_UPLOAD_BUCKET: {
            value: 'langfuse'
          }
          LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT: {
            value: objectStore.properties.endpoint
          }
          LANGFUSE_S3_EVENT_UPLOAD_PREFIX: {
            value: 'events/'
          }
          LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY: {
            valueFrom: {
              secretKeyRef: {
                secretName: objectStore.properties.secrets.name
                key: 'accountKey'
              }
            }
          }
          LANGFUSE_S3_MEDIA_UPLOAD_ACCESS_KEY_ID: {
            value: objectStore.properties.accountName
          }
          LANGFUSE_S3_MEDIA_UPLOAD_BUCKET: {
            value: 'langfuse'
          }
          LANGFUSE_S3_MEDIA_UPLOAD_ENDPOINT: {
            value: objectStore.properties.endpoint
          }
          LANGFUSE_S3_MEDIA_UPLOAD_PREFIX: {
            value: 'media/'
          }
          LANGFUSE_S3_MEDIA_UPLOAD_SECRET_ACCESS_KEY: {
            valueFrom: {
              secretKeyRef: {
                secretName: objectStore.properties.secrets.name
                key: 'accountKey'
              }
            }
          }
          LANGFUSE_USE_AZURE_BLOB: {
            value: 'true'
          }
          NEXTAUTH_SECRET: {
            valueFrom: {
              secretKeyRef: {
                secretName: appSecrets.name
                key: 'nextAuthSecret'
              }
            }
          }
          NEXTAUTH_URL: {
            value: nextAuthUrl
          }
          REDIS_AUTH: {
            valueFrom: {
              secretKeyRef: {
                secretName: redisCache.properties.secrets.name
                key: 'accessKey'
              }
            }
          }
          REDIS_HOST: {
            value: redisCache.properties.host
          }
          REDIS_PORT: {
            value: string(redisCache.properties.port)
          }
          REDIS_TLS_ENABLED: {
            value: 'true'
          }
          SALT: {
            valueFrom: {
              secretKeyRef: {
                secretName: appSecrets.name
                key: 'salt'
              }
            }
          }
        }
        ports: {
          web: {
            containerPort: 3000
          }
        }
      }
    }
  }
}

resource workerContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'worker'
  properties: {
    environment: environment
    application: app.id
    codeReference: 'worker/src/index.ts#L19'
    containers: {
      worker: {
        image: workerImage.properties.imageReference
        env: {
          CLICKHOUSE_CLUSTER_ENABLED: {
            value: 'false'
          }
          CLICKHOUSE_MIGRATION_URL: {
            value: 'clickhouse://${clickhouseContainer.properties.hosts.clickhouse}:9000'
          }
          CLICKHOUSE_PASSWORD: {
            valueFrom: {
              secretKeyRef: {
                secretName: appSecrets.name
                key: 'clickhousePassword'
              }
            }
          }
          CLICKHOUSE_URL: {
            value: 'http://${clickhouseContainer.properties.hosts.clickhouse}:8123'
          }
          CLICKHOUSE_USER: {
            value: 'clickhouse'
          }
          DATABASE_ARGS: {
            value: 'sslmode=require'
          }
          DATABASE_HOST: {
            value: postgresDb.properties.host
          }
          DATABASE_NAME: {
            value: 'langfuse'
          }
          DATABASE_PASSWORD: {
            valueFrom: {
              secretKeyRef: {
                secretName: appSecrets.name
                key: 'databasePassword'
              }
            }
          }
          DATABASE_USERNAME: {
            value: 'myadmin'
          }
          ENCRYPTION_KEY: {
            valueFrom: {
              secretKeyRef: {
                secretName: appSecrets.name
                key: 'encryptionKey'
              }
            }
          }
          LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID: {
            value: objectStore.properties.accountName
          }
          LANGFUSE_S3_EVENT_UPLOAD_BUCKET: {
            value: 'langfuse'
          }
          LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT: {
            value: objectStore.properties.endpoint
          }
          LANGFUSE_S3_EVENT_UPLOAD_PREFIX: {
            value: 'events/'
          }
          LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY: {
            valueFrom: {
              secretKeyRef: {
                secretName: objectStore.properties.secrets.name
                key: 'accountKey'
              }
            }
          }
          LANGFUSE_S3_MEDIA_UPLOAD_ACCESS_KEY_ID: {
            value: objectStore.properties.accountName
          }
          LANGFUSE_S3_MEDIA_UPLOAD_BUCKET: {
            value: 'langfuse'
          }
          LANGFUSE_S3_MEDIA_UPLOAD_ENDPOINT: {
            value: objectStore.properties.endpoint
          }
          LANGFUSE_S3_MEDIA_UPLOAD_PREFIX: {
            value: 'media/'
          }
          LANGFUSE_S3_MEDIA_UPLOAD_SECRET_ACCESS_KEY: {
            valueFrom: {
              secretKeyRef: {
                secretName: objectStore.properties.secrets.name
                key: 'accountKey'
              }
            }
          }
          LANGFUSE_USE_AZURE_BLOB: {
            value: 'true'
          }
          NEXTAUTH_URL: {
            value: nextAuthUrl
          }
          REDIS_AUTH: {
            valueFrom: {
              secretKeyRef: {
                secretName: redisCache.properties.secrets.name
                key: 'accessKey'
              }
            }
          }
          REDIS_HOST: {
            value: redisCache.properties.host
          }
          REDIS_PORT: {
            value: string(redisCache.properties.port)
          }
          REDIS_TLS_ENABLED: {
            value: 'true'
          }
          SALT: {
            valueFrom: {
              secretKeyRef: {
                secretName: appSecrets.name
                key: 'salt'
              }
            }
          }
        }
        ports: {
          worker: {
            containerPort: 3030
          }
        }
      }
    }
  }
}

resource webRoute 'Radius.Compute/routes@2025-08-01-preview' = {
  name: 'web-route'
  properties: {
    environment: environment
    application: app.id
    codeReference: 'docker-compose.yml#L82'
    kind: 'HTTP'
    rules: [
      {
        matches: [
          {
            httpPath: '/'
          }
        ]
        destinationContainer: {
          resourceId: webContainer.id
          containerName: 'web'
          containerPort: 3000
        }
      }
    ]
  }
}

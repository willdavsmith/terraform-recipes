extension radius
extension radiusComputeContainers
extension radiusDataPostgreSqlDatabases
extension radiusSecuritySecrets

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

@description('The username for the PostgreSQL database.')
param username string

@description('The password for the PostgreSQL database.')
@secure()
param password string

resource todolist 'Radius.Core/applications@2025-08-01-preview'= {
  name: 'todolist'
  properties: {
    environment: environment
  }
}

resource frontend 'radiusComputeContainers:Radius.Compute/containers@2025-08-01-preview' = {
  name: 'frontend'
  properties: {
    application: todolist.id
    container: {
      image: 'ghcr.io/radius-project/samples/demo:latest'
      ports: {
        web: {
          containerPort: 3000
        }
      }
    }
    connections: {
      postgresql: {
        source: postgresql.id
      }
    }
  }
}

resource postgresql 'radiusDataPostgreSqlDatabases:Radius.Data/postgreSqlDatabases@2025-08-01-preview' = {
  name: 'postgresql'
  properties: {
    environment: environment
    application: todolist.id
    credentials: {
      source: credentials.id
    }
  }
}

resource credentials 'radiusSecuritySecrets:Radius.Security/secrets@2025-08-01-preview' = {
  name: 'credentials'
  properties: {
    environment: environment
    application: todolist.id
    data: {
      username: {
        value: username
      }
      password: {
        value: password
      }
    }
  }
}

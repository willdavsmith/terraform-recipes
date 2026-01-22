extension radius
extension mycompany_databases

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

@description('The password for the PostgreSQL database.')
@secure()
param password string

resource todolist 'radius:Applications.Core/applications@2023-10-01-preview' = {
  name: 'todolist'
  properties: {
    environment: environment
  }
}

resource frontend 'radius:Applications.Core/containers@2023-10-01-preview' = {
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

resource postgresql 'mycompany_databases:MyCompany.Databases/postgreSqlDatabases@2026-01-12' = {
  name: 'postgresql'
  properties: {
    environment: environment
    application: todolist.id
    password: password
  }
}

oc -n default create secret generic filebrowser-admin \
  --from-literal=username='adminocp' --from-literal=password='P@ssw0rd'

cat <<'EOF' | oc apply -n default -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: filebrowser
  labels:
    app: filebrowser
spec:
  replicas: 1
  selector:
    matchLabels:
      app: filebrowser
  template:
    metadata:
      labels:
        app: filebrowser
    spec:
      containers:
      - name: filebrowser
        image: quay.io/lexsugar/filebrowser:v2
        command: ["/bin/sh", "-c"]
        args:
        - |
          DB=/database/fb.db
          filebrowser config init -d $DB --minimumPasswordLength 8 2>/dev/null || filebrowser config init -d $DB
          filebrowser users add "$FB_USER" "$FB_PASS" --perm.admin -d $DB &&
          exec filebrowser -d $DB -r /srv -a 0.0.0.0 -p 8080
        env:
        - name: FB_USER
          valueFrom:
            secretKeyRef:
              name: filebrowser-admin
              key: username
        - name: FB_PASS
          valueFrom:
            secretKeyRef:
              name: filebrowser-admin
              key: password
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 500m
            memory: 256Mi
        volumeMounts:
        - name: srv
          mountPath: /srv
        - name: database
          mountPath: /database
      volumes:
      - name: srv
        emptyDir: {}
      - name: database
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: filebrowser
spec:
  selector:
    app: filebrowser
  ports:
  - name: http
    port: 8080
    targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: filebrowser
spec:
  to:
    kind: Service
    name: filebrowser
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

oc -n default rollout status deploy/filebrowser

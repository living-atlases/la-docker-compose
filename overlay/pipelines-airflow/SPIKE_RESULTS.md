# SPIKE_RESULTS — Correr los DAGs de pipelines-airflow sin AWS (vía la-docker-compose)

Fecha: 2026-06-22 · Base: `develop` @ adf3a27 (limpio; drafts archivados en
`../pipelines-airflow-drafts-backup-2026-06-22.zip` y `git stash@{0}`).

## Pregunta del spike
¿Pueden los DAGs (que esconden la lógica operativa real) correr sin AWS contra el
`la_pipelines` local de la-docker-compose, y debe la lógica no-EMR vivir como **overlay**
(cero impacto a ALA) o como **PR opt-in** en el repo?

## Resultados

### E1 — Storage por configuración: ✅ PASS (verificado)
boto3 1.43 redirige a MinIO **solo con env** (`AWS_ENDPOINT_URL_S3`, credenciales), sin
tocar código. Probados los patrones exactos de `load_dataset_dag.py`:
`client.upload_file(...)` y `resource("s3").Bucket().objects.filter(Prefix=...)`.
→ El seam de almacenamiento es **gratis** (MinIO como S3 local). `e1-storage/`.

### E2 — Cómputo por overlay sin tocar DAGs: ✅ PASS (mecanismo + traducción)
- **Cobertura (análisis estático):** 12 DAGs entran por `cluster_setup.run_large_emr`, pero
  **5 inlinean los operadores EMR** (`ingest_small_datasets`, `ingest_large_datasets`,
  `export_event_core`, `generate_parquet`, `pre_ingest_drs`) — incl. los workhorses. ⇒ un
  overlay por *function-shadow* de `run_large_emr` NO basta.
- **Solución robusta:** sustituir las **4 clases de operador EMR**
  (`EmrCreateJobFlowOperator`, `EmrAddStepsOperator`, `EmrStepSensor`, `EmrJobFlowSensor`)
  vía `sitecustomize` al arranque. Cubre AMBOS caminos (run_large_emr también las usa).
- **Traducción de steps (verificada con los builders REALES del repo):** los step-dicts
  son introspectables — `s3-dist-cp.jar` ⇒ no-op (datos en volumen compartido);
  `command-runner.jar` + `bash -c "<cmd>"` ⇒ `<cmd>` con `--cluster`→`--local`, ejecutado
  en `la_pipelines`. NO hace falta sustituir `s3_cp`/`step_bash_cmd`. `e2-overlay/`.
- **Timing del swap:** probado que parchear el atributo del módulo antes del
  `from ...emr import X` del DAG entrega el shim (sitecustomize corre antes del parseo).

### E3 — PR opt-in en el repo: (no implementado; resuelto por análisis)
El artefacto del swap (un módulo shim + hook `sitecustomize`/plugin) es **el mismo** tanto
si vive fuera (overlay) como dentro del repo. Diferencia = dónde se hospeda, no viabilidad.
Nota: el `ala_config` committeado está **AWS-hardcoded** (sin `cloud_provider`/`is_aws`; la
abstracción solo existía en los drafts corruptos), así que el overlay debe **sembrar ~40
Variables dummy** (EMR/EC2/S3) además del swap y el env de boto3.

### E4 — End-to-end real: ⏸ PENDIENTE (fase pesada)
Requiere Airflow real + imagen `la-pipelines` funcional + Solr. Bloqueo conocido: el
contenedor `la_pipelines` de la-docker-compose está **inestable (Exit 137)** y su config usa
rutas **HDFS** sin Hadoop desplegado (hay que pasar a `file:///data/...`). Es trabajo de
la-docker-compose, no de pipelines-airflow.

## Recomendación
**Overlay hospedado en la-docker-compose** (lo que menos afecta a ALA: cero cambios en el
repo upstream). Tres piezas, todas validadas en mecanismo:
1. **Storage:** env `AWS_ENDPOINT_URL_S3`→MinIO (E1). 
2. **Cómputo:** `sitecustomize` que swapea las 4 clases EMR por shims locales que ejecutan
   `la-pipelines <stage> --local` en `la_pipelines` y vuelven no-op las copias (E2).
3. **Config:** sembrar las Variables (servicios reales + dummies EMR) al iniciar Airflow.

El mismo shim se puede **ofrecer luego a ALA** como plugin opcional (PR) si lo quieren, pero
no es necesario para que la comunidad lo use.

## Siguientes pasos (fase de implementación)
1. En la-docker-compose: arreglar `la_pipelines` (rutas `file:///`, memoria) + añadir
   servicio `airflow` (monta `pipelines-airflow/dags` + el `sitecustomize` overlay) + MinIO.
2. Mapear el fixture de Variables a los nombres del `ala_config` committeado.
3. E4: `Load_dataset` → `Ingest_small_datasets` con un dataset pequeño; verificar Solr +
   biocache-service.

## Artefactos
- `e1-storage/` — compose MinIO + test boto3 (PASS).
- `e2-overlay/emr_local_shim.py` — shim + traducción de steps.
- `e2-overlay/test_overlay_mechanism.py` — usa los builders reales del repo (PASS).
- `e4-airflow/` — fixtures de Variables recuperados (para la fase E4).

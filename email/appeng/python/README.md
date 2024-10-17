# Test locally

## Start the server

Check [Running the sample locally] for more details

1. Create an isolated Python environment
    
    ```bash
    python3 -m venv env
    source env/bin/activate
    ```

2. Install dependencies

    ```bash
    cd email/appeng/python/
    pip install -r requirements.txt
    ```
3. Start the server

    ```bash
    export GOOGLE_CLOUD_PROJECT=[your-project-id]
    export PUBSUB_TOPIC=[your-topic]
    python main.py
    ```

## Simulate push notifications

```bash
curl -H "Content-Type: application/json" -i --data @sample_message_success.json "localhost:8080/pubsub/push"
curl -H "Content-Type: application/json" -i --data @sample_message_failure.json "localhost:8080/pubsub/push"
```
[Running the sample locally]: https://cloud.google.com/appengine/docs/flexible/writing-and-responding-to-pub-sub-messages?tab=python#run_the_sample_locally
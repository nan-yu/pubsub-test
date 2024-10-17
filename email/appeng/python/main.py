# Copyright 2024 Google LLC.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

from flask import Flask, request, current_app, jsonify
import json
import logging
import os
import sys

# Add the common directory to the Python path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', 'common', 'python')))
# Import the sendmail function
from send_email import sendmail

app = Flask(__name__)

# Configure the following environment variables via app.yaml
# This is used in the push request handler to verify that the request came from
# pubsub and originated from a trusted source.
app.config["PUBSUB_TOPIC"] = os.environ["PUBSUB_TOPIC"]
app.config["MAIL_FROM"] = os.environ["MAIL_FROM"]
app.config["MAIL_TO"] = os.environ["MAIL_TO"]
app.config["MAIL_SERVER"] = os.environ["MAIL_SERVER"]
app.config["MAIL_PASSWORD"] = os.environ["MAIL_PASSWORD"]

logging.basicConfig(level=logging.DEBUG)  # Set the desired logging level

# [START gae_flex_pubsub_push]
@app.route("/pubsub/push", methods=["POST"])
def pubsub_push():
  """Handles Pub/Sub push messages."""

  try:
    envelope = json.loads(request.data.decode("utf-8"))
  except json.JSONDecodeError:
    return "Invalid JSON payload", 400

  logging.info("Received message: %s", envelope)

  # Extract message data
  rs_namespace = envelope["message"].get("RSNamespace")
  rs_name = envelope["message"].get("RSName")
  project = envelope["message"].get("projectID")
  cluster = envelope["message"].get("cluster")
  commit = envelope["message"].get("commit")
  status = envelope["message"].get("status")
  error = envelope["message"].get("error")

  # Determine the RSync kind
  rs_kind = "RootSync" if rs_namespace == "config-management-system" else "RepoSync"

  # Construct the subject and body
  subject = f"{rs_kind} {rs_namespace}/{rs_name} {status}"
  body = f"{subject} with commit {commit} on cluster {cluster} in project {project}"
  body = body if not error else f"{body} with error {error}"

  logging.info("Subject: %s", subject)
  logging.info("Body: %s", body)

  # Send email
  sendmail(subject, body)

  # Send a success response
  return jsonify({"message": "Message received successfully"}), 200

# [END gae_flex_pubsub_push]


@app.errorhandler(500)
def server_error(e):
  logging.exception("An error occurred during a request.")
  return (
      """
  An internal error occurred: <pre>{}</pre>
  See logs for full stacktrace.
  """.format(
          e
      ),
      500,
  )


if __name__ == "__main__":
  # This is used when running locally. Gunicorn is used to run the
  # application on Google App Engine. See entrypoint in app.yaml.
  app.run(host="127.0.0.1", port=8080, debug=True)

// [START functions_cloudevent_pubsub]

package email

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"

	_ "github.com/GoogleCloudPlatform/functions-framework-go/funcframework"
	"github.com/GoogleCloudPlatform/functions-framework-go/functions"
	"github.com/cloudevents/sdk-go/v2/event"
	gomail "gopkg.in/mail.v2"
)

const (
	mailFrom = "cs-pubsub-test@google.com"
	mailTo   = "cs-pubsub-test@google.com"
	mailHost = "smtp.gmail.com"
	mailPort = 465

	mailUsernameKey = "MAIL_USER"
	mailPasswordKey = "MAIL_PASSWD"
)

func init() {
	functions.CloudEvent("ConfigSync", sendEmail)
}

// MessagePublishedData contains the full Pub/Sub message
// See the documentation for more details:
// https://cloud.google.com/eventarc/docs/cloudevents#pubsub
type MessagePublishedData struct {
	Message PubSubMessage
}

// PubSubMessage is the payload of a Pub/Sub event.
// See the documentation for more details:
// https://cloud.google.com/pubsub/docs/reference/rest/v1/PubsubMessage
type PubSubMessage struct {
	Data []byte `json:"data"`
}

// sendEmail consumes a CloudEvent message and extracts the Pub/Sub message.
func sendEmail(ctx context.Context, e event.Event) error {
	var msg MessagePublishedData
	if err := e.DataAs(&msg); err != nil {
		return fmt.Errorf("event.DataAs: %w", err)
	}

	subject, err := mailSubject(msg.Message.Data)
	if err != nil {
		return err
	}

	config := mailConfig{
		from:     mailFrom,
		to:       mailTo,
		subject:  subject,
		body:     string(msg.Message.Data),
		server:   mailHost,
		port:     mailPort,
		username: os.Getenv(mailUsernameKey),
		password: os.Getenv(mailPasswordKey),
	}

	if err := send(config); err != nil {
		return err
	}
	log.Printf("Mail sent successfully")
	return nil
}

type mailConfig struct {
	from     string
	to       string
	subject  string
	body     string
	server   string
	port     int
	username string
	password string
}

func send(config mailConfig) error {
	message := gomail.NewMessage()

	message.SetHeader("From", config.from)
	message.SetHeader("To", config.to)
	message.SetHeader("Subject", config.subject)
	message.SetBody("text/plain", config.body)

	dialer := gomail.NewDialer(config.server, config.port, config.username, config.password)

	return dialer.DialAndSend(message)
}

func mailSubject(data []byte) (string, error) {
	csMessage := &ConfigSyncMessage{}
	if err := json.Unmarshal(data, csMessage); err != nil {
		return "", fmt.Errorf("unmarshaling Config Sync message: %v", err)
	}

	var rsKind string
	if csMessage.RSNamespace == "config-management-system" {
		rsKind = "RootSync"
	} else {
		rsKind = "RepoSync"
	}

	return fmt.Sprintf("%s %s/%s %s", rsKind, csMessage.RSNamespace, csMessage.RSName, csMessage.Status), nil
}

type ConfigSyncMessage struct {
	ProjectID   string `json:"projectID"`
	ClusterName string `json:"clusterName"`
	NodeName    string `json:"nodeName"`
	Topic       string `json:"topic"`
	RSNamespace string `json:"RSNamespace"`
	RSName      string `json:"RSName"`
	Commit      string `json:"commit,omitempty"`
	Status      string `json:"status"`
	Error       string `json:"error,omitempty"`
}

// [END functions_cloudevent_pubsub]

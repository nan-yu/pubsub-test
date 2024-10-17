import os
import smtplib
from email.message import EmailMessage

def sendmail(subject, body):
  """Sends an email with the given subject and body."""

  # Fetch environment variables, providing default values if not set
  mail_from = os.environ.get('MAIL_FROM', '').strip()
  mail_to = os.environ.get('MAIL_TO', '').strip()
  mail_server = os.environ.get('MAIL_SERVER', '').strip()
  mail_password = os.environ.get('MAIL_PASSWORD', '').strip()

  # Create and populate the email message
  message = EmailMessage()
  message.set_content(body)
  message['Subject'] = subject
  message['From'] = mail_from
  message['To'] = mail_to

  # Send the email
  with smtplib.SMTP_SSL(mail_server) as smtp_server:
    smtp_server.login(mail_from, mail_password)
    smtp_server.send_message(message)
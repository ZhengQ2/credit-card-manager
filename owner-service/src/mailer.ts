import { SESv2Client, SendEmailCommand } from '@aws-sdk/client-sesv2';

export interface Mailer {
  sendLoginCode(to: string, code: string): Promise<void>;
}

const subject = 'Your Card Ledger sign-in code';
const body = (code: string) =>
  `Your Card Ledger sign-in code is ${code}\n\nIt expires in 10 minutes and works once. ` +
  `If you didn't try to sign in, you can ignore this email.\n`;

/** Mock mode only: prints the code to the service log so local testing needs no email. */
export class ConsoleMailer implements Mailer {
  async sendLoginCode(to: string, code: string) {
    const masked = to.replace(/^(.).*(@.*)$/, '$1***$2');
    console.log(`[mock mail] sign-in code for ${masked}: ${code}`);
  }
}

export class SesMailer implements Mailer {
  private readonly ses: SESv2Client;
  private readonly from: string;
  constructor(from: string, region: string) {
    this.from = from;
    this.ses = new SESv2Client({ region });
  }

  async sendLoginCode(to: string, code: string) {
    await this.ses.send(new SendEmailCommand({
      FromEmailAddress: this.from,
      Destination: { ToAddresses: [to] },
      Content: { Simple: {
        Subject: { Data: subject, Charset: 'UTF-8' },
        Body: { Text: { Data: body(code), Charset: 'UTF-8' } },
      } },
    }));
  }
}

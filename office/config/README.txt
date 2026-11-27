Own templates of the Office MCP server (mounted read-only to /app/custom_templates):
  custom_docx_template.docx        Word: letterhead, styles, header/footer for every document
  custom_pptx_template_16_9.pptx   PowerPoint 16:9 (custom_pptx_template_4_3.pptx for 4:3)
  custom_email_template.html       e-mail drafts
Template tools with {{placeholders}} are registered in /opt/office/config (docx_templates.yaml, email_templates.yaml,
pptx_templates.yaml). Details: https://github.com/ForLegalAI/mcp-ms-office-documents/blob/main/docs/templates.md
The files are re-read on change, no restart needed.

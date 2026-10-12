FROM ghcr.io/smanx/deepseek-harness:admin-latest

# Install system dependencies (apt)
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        python3 \
        python3-pip \
        python-is-python3 \
        tesseract-ocr \
        tesseract-ocr-eng \
        tesseract-ocr-osd \
        ffmpeg \
        libreoffice-writer \
        libreoffice-calc \
        libreoffice-impress \
        libreoffice-common \
        libreoffice-core \
        poppler-utils \
        poppler-data && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install Python packages (pip)
RUN pip3 install --no-cache-dir --break-system-packages \
        mammoth \
        python-pptx \
        openpyxl \
        xlrd \
        xlsxwriter \
        pypdf \
        pypdfium2 \
        pdfminer.six \
        pdfplumber \
        pdf2image \
        reportlab \
        beautifulsoup4 \
        markdownify \
        markitdown \
        lxml \
        pandas \
        numpy \
        SpeechRecognition \
        pydub \
        pytesseract \
        azure-ai-documentintelligence \
        azure-ai-contentunderstanding \
        azure-core \
        azure-identity \
        msal \
        msal-extensions \
        requests \
        python-dotenv \
        defusedxml \
        cobble

# Install global npm packages
RUN npm install -g --loglevel=warn \
        docx \
        @firecrawl/anydoc

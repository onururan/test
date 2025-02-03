import csv
import pdfplumber
import pandas as pd
from collections import Counter
from itertools import zip_longest

def pdf_to_csv(pdf_path, csv_path):
    # Use pdfplumber to open the PDF file
    with pdfplumber.open(pdf_path) as pdf:
        all_rows = []
        max_columns = 0

        # Iterate through the pages of the PDF
        for page in pdf.pages:
            print(f"Processing page {page.page_number}")
            if page.extract_table():
                # Extract the table from the PDF page if it exists
                rows = page.extract_table()
                all_rows.extend(rows)
                max_columns = max(max_columns, len(rows[0]) if rows else 0)

    # Ensure all rows have the same number of columns
    all_rows = [
        row + [None] * (max_columns - len(row)) if len(row) < max_columns else row
        for row in all_rows
    ]

    # Convert the list of rows to a DataFrame
    df = pd.DataFrame(all_rows[1:], columns=all_rows[0])

    # Save the DataFrame to a CSV file
    df.to_csv(csv_path, index=False)

    print(f"CSV file saved to {csv_path}")

if __name__ == "__main__":
    # Path to the input PDF file
    pdf_path = "sample.pdf"
    # Path to the output CSV file
    csv_path = "output.csv"

    pdf_to_csv(pdf_path, csv_path)

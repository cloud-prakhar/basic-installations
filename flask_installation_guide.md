# Flask Installation Guide — Windows, WSL & macOS

Flask is a lightweight Python web framework. This guide walks through installing it on **Windows** (using Command Prompt or PowerShell), **WSL** (Windows Subsystem for Linux), and **macOS** (using Terminal).

---

## Prerequisites

- Python 3.x installed
- `pip` available (comes bundled with Python 3.4+)

To verify:
```bash
python --version
pip --version
```

---

## Part 1 — Installing Flask on Windows

### Step 1: Open Command Prompt or PowerShell

Press `Win + R`, type `cmd` or `powershell`, and press Enter.

### Step 1b: (If `python` is not in PATH) Use the Full Python Installation Path

If `python` is not recognized, you can use the full path to your Python executable instead of relying on the `python` command.

**Find your Python installation path:**
```cmd
where python
```

Common default locations:
```
C:\Users\<YourUsername>\AppData\Local\Programs\Python\Python3xx\python.exe
C:\Python3xx\python.exe
```

You can also find it from the Python installer — open **Apps & Features** → search for Python → click **Modify** to see the install location.

**Use the full path for all commands:**
```cmd
C:\Users\<YourUsername>\AppData\Local\Programs\Python\Python311\python.exe -m venv venv
C:\Users\<YourUsername>\AppData\Local\Programs\Python\Python311\python.exe -m pip install flask
C:\Users\<YourUsername>\AppData\Local\Programs\Python\Python311\python.exe -m flask --version
```

> **Tip:** To avoid typing the full path every time, add Python to your PATH permanently:
> 1. Search **"Environment Variables"** in the Start menu
> 2. Click **"Edit the system environment variables"**
> 3. Click **"Environment Variables"** → select **Path** → click **Edit**
> 4. Click **New** and add both:
>    - `C:\Users\<YourUsername>\AppData\Local\Programs\Python\Python311\`
>    - `C:\Users\<YourUsername>\AppData\Local\Programs\Python\Python311\Scripts\`
> 5. Click OK, restart your terminal

---

### Step 2: (Recommended) Create a Virtual Environment

```cmd
python -m venv venv
venv\Scripts\activate
```

You should see `(venv)` appear at the start of your prompt.

### Step 3: Install Flask

```cmd
pip install flask
```

### Step 4: Verify Installation

```cmd
python -m flask --version
```

Expected output (version numbers may vary):
```
Python 3.x.x
Flask 3.x.x
Werkzeug 3.x.x
```

### Step 5: Run a Test App

Create a file called `app.py`:
```python
from flask import Flask

app = Flask(__name__)

@app.route("/")
def home():
    return "Hello, Flask is working!"

if __name__ == "__main__":
    app.run(debug=True)
```

Run it:
```cmd
python app.py
```

Open your browser and go to `http://127.0.0.1:5000`

---

## Part 2 — Installing Flask on WSL (Ubuntu/Debian)

### Step 1: Open WSL Terminal

Press `Win + R`, type `wsl`, press Enter — or open **Ubuntu** from the Start menu.

### Step 2: Update Package Lists

```bash
sudo apt update && sudo apt upgrade -y
```

### Step 3: Install Python and pip (if not already installed)

```bash
sudo apt install python3 python3-pip python3-venv -y
```

### Step 4: (Recommended) Create a Virtual Environment

```bash
python3 -m venv venv
source venv/bin/activate
```

You should see `(venv)` appear at the start of your prompt.

### Step 5: Install Flask

```bash
pip install flask
```

### Step 6: Verify Installation

```bash
python -m flask --version
```

### Step 7: Run a Test App

Create `app.py` (same code as the Windows example above), then:

```bash
python app.py
```

Open your browser and go to `http://127.0.0.1:5000`

> **Note:** In WSL, the browser runs on Windows. The `127.0.0.1` address should still work because WSL 2 forwards localhost ports automatically.

---

## Part 3 — Installing Flask on macOS

### Step 1: Open Terminal

Press `Cmd + Space`, type `Terminal`, and press Enter.

### Step 2: Check if Python is installed

macOS ships with Python 2 on older versions. Always ensure you have Python 3:

```bash
python3 --version
```

If Python 3 is not installed, install it via **Homebrew** (recommended):

```bash
# Install Homebrew if you don't have it
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Then install Python
brew install python
```

### Step 3: (If needed) Use the Full Python Installation Path

If `python3` is not recognized, find it with:

```bash
which python3
```

Common default locations on macOS:
```
/usr/bin/python3                          # system Python (macOS built-in)
/usr/local/bin/python3                    # Homebrew (Intel Mac)
/opt/homebrew/bin/python3                 # Homebrew (Apple Silicon / M1/M2/M3)
/Library/Frameworks/Python.framework/Versions/3.xx/bin/python3   # python.org installer
```

**Use the full path for all commands:**
```bash
/opt/homebrew/bin/python3 -m venv venv
/opt/homebrew/bin/python3 -m pip install flask
/opt/homebrew/bin/python3 -m flask --version
```

> **Tip:** To add Homebrew Python to your PATH permanently, add this line to your shell config file (`~/.zshrc` for zsh, `~/.bash_profile` for bash):
> ```bash
> # For Apple Silicon (M1/M2/M3):
> export PATH="/opt/homebrew/bin:$PATH"
>
> # For Intel Mac:
> export PATH="/usr/local/bin:$PATH"
> ```
> Then reload: `source ~/.zshrc`

### Step 4: (Recommended) Create a Virtual Environment

```bash
python3 -m venv venv
source venv/bin/activate
```

You should see `(venv)` appear at the start of your prompt.

### Step 5: Install Flask

```bash
pip install flask
```

### Step 6: Verify Installation

```bash
python -m flask --version
```

### Step 7: Run a Test App

Create `app.py` (same code as the Windows example above), then:

```bash
python app.py
```

Open your browser and go to `http://127.0.0.1:5000`

---

## Part 4 — Command Troubleshooting

### `python` not recognized / `'python' is not recognized as an internal or external command`

**Windows:**
- Python may not be in your PATH. Reinstall Python and check **"Add Python to PATH"** during setup.
- Try using `python3` instead of `python`.
- As an immediate workaround, use the **full installation path** (see Step 1b in Part 1):
  ```cmd
  C:\Users\<YourUsername>\AppData\Local\Programs\Python\Python311\python.exe --version
  ```

**WSL:**
```bash
which python3    # should return /usr/bin/python3
sudo apt install python3 -y
```

**macOS:**
```bash
which python3    # should return a path like /usr/bin/python3 or /opt/homebrew/bin/python3
brew install python
```

---

### `pip` not found

**Windows:**
```cmd
python -m ensurepip --upgrade
python -m pip install --upgrade pip
```

**WSL:**
```bash
sudo apt install python3-pip -y
pip3 install --upgrade pip
```

**macOS:**
```bash
python3 -m ensurepip --upgrade
python3 -m pip install --upgrade pip
```

---

### `pip install flask` fails with permissions error

Never use `sudo pip install` — it can break system Python.

**Correct fix — use a virtual environment:**
```bash
python3 -m venv venv
source venv/bin/activate   # macOS/WSL/Linux
# OR
venv\Scripts\activate      # Windows
pip install flask
```

**macOS only:** If you see an `externally-managed-environment` error (Python 3.11+), this is macOS blocking global pip installs. A virtual environment is the correct solution:
```bash
python3 -m venv venv
source venv/bin/activate
pip install flask
```

---

### Virtual environment won't activate on Windows (PowerShell)

PowerShell may block script execution. Run:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```
Then try activating again:
```powershell
venv\Scripts\Activate.ps1
```

---

### Flask app won't start — `Address already in use`

Another process is using port 5000. Run on a different port:
```bash
python app.py --port 5001
```
Or in code:
```python
app.run(debug=True, port=5001)
```

To find and kill the process using port 5000:

**Windows:**
```cmd
netstat -ano | findstr :5000
taskkill /PID <PID_NUMBER> /F
```

**WSL/Linux/macOS:**
```bash
lsof -i :5000
kill -9 <PID_NUMBER>
```

> **macOS note:** macOS Monterey and later uses port 5000 for AirPlay Receiver. Either disable AirPlay Receiver in **System Settings → General → AirDrop & Handoff**, or run Flask on a different port (e.g., 5001).

---

### `ModuleNotFoundError: No module named 'flask'`

Your virtual environment is not activated. Always activate before running:

**Windows:**
```cmd
venv\Scripts\activate
```

**WSL/Linux/macOS:**
```bash
source venv/bin/activate
```

Then verify Flask is installed:
```bash
pip show flask
```

---

### WSL: Browser can't reach `http://127.0.0.1:5000`

- Make sure Flask is running with `host='0.0.0.0'` if using WSL 1:
  ```python
  app.run(debug=True, host='0.0.0.0')
  ```
- WSL 2 users: `127.0.0.1` usually works automatically. If not, find your WSL IP:
  ```bash
  hostname -I
  ```
  Use that IP address in your browser instead.

---

### `flask: command not found` (after pip install)

The Flask CLI is not in your PATH. Use the module form instead:
```bash
python -m flask run
```

Or ensure your virtual environment is activated (the most common cause).

---

### macOS: `zsh: command not found: python`

macOS uses `python3` by default — the `python` alias may not exist. Use:
```bash
python3 app.py
python3 -m flask run
```

Or create an alias in `~/.zshrc`:
```bash
alias python=python3
alias pip=pip3
```
Then reload: `source ~/.zshrc`

---

## Quick Reference Cheat Sheet

| Task | Windows | WSL/Linux | macOS |
|------|---------|-----------|-------|
| Create venv | `python -m venv venv` | `python3 -m venv venv` | `python3 -m venv venv` |
| Activate venv | `venv\Scripts\activate` | `source venv/bin/activate` | `source venv/bin/activate` |
| Deactivate venv | `deactivate` | `deactivate` | `deactivate` |
| Install Flask | `pip install flask` | `pip install flask` | `pip install flask` |
| Check Flask version | `python -m flask --version` | `python -m flask --version` | `python -m flask --version` |
| Run app | `python app.py` | `python app.py` | `python3 app.py` |
| Run with Flask CLI | `flask run` | `flask run` | `flask run` |
| Run on custom port | `flask run --port 5001` | `flask run --port 5001` | `flask run --port 5001` |
| Find Python path | `where python` | `which python3` | `which python3` |

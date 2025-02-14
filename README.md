# Zeppelin.nvim

Zeppelin.nvim is a Neovim plugin that allows users to interact with Apache Zeppelin notebooks directly from Neovim. It provides an interface to authenticate, list notebooks, open and edit paragraphs, and execute code within Zeppelin.

## Motivation
I created this plugin because I refused to use IntelliJ and I used to use Apache Zeppelin web UI to write and execute code in notebooks. I wanted to be able to write and execute code in Zeppelin notebooks directly from Neovim.

## Features
- [x] Authenticate with Zeppelin (`:ZeppelinLogin <username> <password>`)
- [x] List notebooks (`:Zeppelin`)
- [x] Open notebook
- [x] Edit paragraph and save changes 
- [x] Execute code in paragraph
- [x] Optional proxy support
- [ ] Create new notebook
- [ ] Delete notebook
- [ ] Restart interpreter
- [ ] Create new paragraph
- [ ] Delete paragraph
- [ ] Search in all notebooks

## Installation
Use your favorite plugin manager to install this plugin. For example, using lazy.nvim:
```lua
{
    "mihneamanolache/zeppelin.nvim",
    config = function ()
        require('zeppelin').setup({
            ZEPPELIN_URL = "http://your-zeppelin-url:port",
            SOCKS5_PROXY = "your-socks5-proxy", -- Optional
        })
    end
}
```

## Usage
- Authenticate with Zeppelin: `:ZeppelinLogin <username> <password>`
- List notebooks: `:Zeppelin` - This will open a buffer showing all available notebooks. Press `<CR>` on a notebook to open it.
- Filter notebooks: press `f` in the notebooks buffer and type the notebook name to filter notebooks.
- Navigating paragraphs: use `<leader><Right>` and `<leader><Left>` to navigate between paragraphs.
- Saving changes: use `<leader>w` to save changes in a paragraph.
- Running code: use `<leader>r` to run code in a paragraph.

## License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing
Feel free to open an issue or a pull request if you have any suggestions or improvements.
